-- Bot driving probe: bots boarding, driving, waiting for a gunner and handing a seat over, in Run
-- mode with real Roblox physics (tools/bot_driving_sim.py, _combat.py and _takeover.py prove the
-- same code in lupa; this is the part only Studio can answer).
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/bot_driving_probe.lua -WaitSeconds 900
--
-- Lines start "[BRR_Drive]". "PROBLEM" lines are findings. Each part is pcall'd, so one failing
-- still leaves the others' numbers.
--
--   P1 DRIVE     a bot beside a car on a long pad high over the void, its goal 700 studs away past a
--                wall: does it board, go round the wall, stop short of the pad's far edge (a drop)?
--   P2 GUNNER    a bot beside an armed CrocodiloRanger with a far goal: it must board and NOT move
--                (Oliver: "wait till it's manned"); then a second bot is put beside it, which should
--                take the GunnerSeat, and only then does the Ranger drive off.
--   P3 TAKEOVER  the P1 driver, at speed, asked for its seat (BotService.YieldSeat, the call
--                VehicleService makes for a player's "Take over" prompt): time to stop, speed at the
--                moment it gets out, where it stands.
--   P4 ROAM      a real map, 20 bots put down near its parked vehicles, 150 s: how many board, how
--                many drive at once (cap MatchConfig.BotDriversMax), spatial queries per driving think
--                (BotNav.DriveCastsPerSense), recoveries, hazards, wrecks, and think cost.
--
-- NOT covered (needs a person): a real player pressing "Take over" (the server path is P3's; the
-- prompt's visibility is VehicleClient). Manual check for Oliver: in a Play session with bots, walk
-- up to a car a bot is driving -- the prompt should read "Take over"; hold it, the car stops, the bot
-- steps out, you are at the wheel. Try the Ranger's rear prompt "Man the gun" while a bot waits at
-- the wheel: it should drive off with you on the gun.

local MAP_ID = "TralalaTown"
local ROAM_BOTS = 20
local ROAM_SECONDS = 150
local PAD_Y = 1600
local PAD_X = 9000

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_Drive] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end

local MapGenerator = mod("MapGenerator")
local CombatService = mod("CombatService")
local VehicleService = mod("VehicleService")
local BotService = mod("BotService")
local BotNav = mod("BotNav")
local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

VehicleService.Start()

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function rootOf(bot)
	return bot and bot.character and bot.character:FindFirstChild("HumanoidRootPart")
end

local function spawnBot(cframe)
	local list = BotService.Spawn(1, function()
		return cframe
	end, function() end)
	return list[1]
end

local arena = Instance.new("Model")
arena.Name = "BRR_DriveProbeArena"
local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Asphalt
	part.Parent = arena
	return part
end

local function statsCopy()
	local out = {}
	for key, value in pairs(BotService.Stats or {}) do
		out[key] = value
	end
	for key, value in pairs(BotNav.DriveStats or {}) do
		out["drive." .. key] = value
	end
	return out
end

local function report(label, before)
	local after = statsCopy()
	local keys = {}
	for key in pairs(after) do
		if string.find(key, "vehicle") or string.find(key, "drive%.") then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local value = after[key]
		if key == "drive.maxCasts" then
			say("%s %s = %s (budget %d)", label, key, tostring(value), BotNav.DriveCastsPerSense or -1)
			if value > (BotNav.DriveCastsPerSense or 4) then
				say("PROBLEM %s: a driving think made %d spatial queries", label, value)
			end
		else
			say("%s %s = %s", label, key, tostring(value - (before[key] or 0)))
		end
	end
end

local function run(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		say("PROBLEM %s errored: %s", label, tostring(err))
	end
end

--------------------------------------------------------------------------------
-- The pads (P1-P3): 900 x 90 of asphalt, a wall across half of it 250 studs along
--------------------------------------------------------------------------------

say("building map %s", MAP_ID)
local info = MapGenerator.Build(MAP_ID)
BotService.SetRoads(info.roads)
arena.Parent = workspace:WaitForChild("Map")
CombatService.SetEnabled(true)
task.wait(3)

local p1 = Vector3.new(PAD_X, PAD_Y, 0)
block("P1Pad", Vector3.new(90, 2, 900), CFrame.new(p1 + Vector3.new(0, -1, 400)))
block("P1Wall", Vector3.new(45, 12, 4), CFrame.new(p1 + Vector3.new(-12, 6, 250)))
local p2 = Vector3.new(PAD_X + 400, PAD_Y, 0)
block("P2Pad", Vector3.new(90, 2, 900), CFrame.new(p2 + Vector3.new(0, -1, 400)))

local folder = Instance.new("Folder")
folder.Name = "BRR_DriveProbeVehicles"
folder.Parent = workspace

local car = VehicleService.Create(folder, p1 + Vector3.new(0, 3, 30), 0, "car", { model = "TralalaGT" })
	or VehicleService.Create(folder, p1 + Vector3.new(0, 3, 30), 0, "car")
local ranger = VehicleService.Create(folder, p2 + Vector3.new(0, 3, 30), 0, "car", { model = "CrocodiloRanger" })
task.wait(2)

local driver = spawnBot(CFrame.new(p1 + Vector3.new(8, 3.2, 22)))
local waiter = spawnBot(CFrame.new(p2 + Vector3.new(8, 3.2, 22)))
local farP1 = p1 + Vector3.new(0, 0, 700)
local farP2 = p2 + Vector3.new(0, 0, 700)
local before = statsCopy()
BotService.Start()

-- Keep their goals far down their pads (their own wander would pick somewhere else).
local keepGoals = true
task.spawn(function()
	while keepGoals do
		if driver then
			driver.wanderGoal = farP1
		end
		if waiter then
			waiter.wanderGoal = farP2
		end
		task.wait(0.5)
	end
end)

local function chassisOf(model)
	local entry = VehicleService.Get and VehicleService.Get(model)
	return entry and entry.rig and entry.rig.chassis or (model and model.PrimaryPart)
end

run("P1 DRIVE", function()
	local chassis = chassisOf(car)
	local start = chassis.Position
	local boardedAt, topSpeed, wallContact, closest = nil, 0, 0, math.huge
	local t0 = os.clock()
	while os.clock() - t0 < 45 do
		task.wait(0.2)
		if driver.ride and not boardedAt then
			boardedAt = os.clock() - t0
			say("P1 boarded after %.1fs as %s", boardedAt, tostring(driver.ride.role))
		end
		local speed = chassis.AssemblyLinearVelocity.Magnitude
		topSpeed = math.max(topSpeed, speed)
		local wall = arena:FindFirstChild("P1Wall")
		local dz = math.abs(chassis.Position.Z - wall.Position.Z)
		if dz < 6 and chassis.Position.X < wall.Position.X + 25 then
			wallContact += 1
		end
		closest = math.min(closest, (flat(chassis.Position) - flat(farP1)).Magnitude)
		if speed > 25 and chassis.Position.Z > 320 then
			break -- past the wall and under way: P3 takes it from here
		end
	end
	say("P1 travelled %.0f studs, top speed %.0f, %s the wall (samples at it %d), %.0f from goal",
		(chassis.Position - start).Magnitude, topSpeed, wallContact > 3 and "HIT" or "cleared", wallContact, closest)
	if not boardedAt then
		say("PROBLEM P1: the bot never boarded (reason %s)", tostring(driver.lastVehicleExit))
	end
	if chassis.Position.Y < PAD_Y - 10 then
		say("PROBLEM P1: the car fell off the pad")
	end
end)

run("P3 TAKEOVER", function()
	local ride = driver.ride
	if not ride then
		say("PROBLEM P3: no driver to take over from (P1 did not get going)")
		return
	end
	local chassis = ride.drive.chassis
	local asker = spawnBot(CFrame.new(chassis.Position + Vector3.new(12, 3, 0)))
	local speedAsked = chassis.AssemblyLinearVelocity.Magnitude
	local accepted = BotService.YieldSeat(driver, asker, ride.seat)
	local t0 = os.clock()
	while driver.ride and os.clock() - t0 < 5 do
		RunService.Heartbeat:Wait()
	end
	local root = rootOf(driver)
	say("P3 asked at %.0f studs/s: accepted %s, out after %.2fs at %.1f studs/s, standing %.1f studs from the car, seat free %s",
		speedAsked, tostring(accepted), os.clock() - t0, chassis.AssemblyLinearVelocity.Magnitude,
		root and (root.Position - chassis.Position).Magnitude or -1, tostring(ride.seat.Occupant == nil))
	if driver.ride then
		say("PROBLEM P3: the bot was still at the wheel 5 s after the takeover")
	end
	keepGoals = false
end)

run("P2 GUNNER", function()
	local chassis = chassisOf(ranger)
	local start = chassis.Position
	local t0 = os.clock()
	while os.clock() - t0 < 14 do
		task.wait(0.5)
	end
	local role = waiter.ride and waiter.ride.role
	local moved = (chassis.Position - start).Magnitude
	say("P2 alone: role %s, moved %.1f studs in 14 s", tostring(role), moved)
	if role == "driver" and moved > 6 then
		say("PROBLEM P2: the Ranger drove off with nobody on the gun")
	end
	local gunnerBot = spawnBot(CFrame.new(chassis.Position + Vector3.new(-8, 3, -8)))
	local manned, movedAt
	t0 = os.clock()
	while os.clock() - t0 < 25 do
		task.wait(0.25)
		if not manned and gunnerBot.ride then
			manned = os.clock() - t0
			say("P2 second bot boarded after %.1fs as %s (seat %s)", manned, tostring(gunnerBot.ride.role),
				gunnerBot.ride.seat and gunnerBot.ride.seat.Name or "?")
		end
		if manned and not movedAt and (chassis.Position - start).Magnitude > moved + 10 then
			movedAt = os.clock() - t0
		end
	end
	say("P2 manned: %s, drove off %s", manned and "yes" or "NO", movedAt and string.format("after %.1fs", movedAt) or "NO")
	if not manned then
		say("PROBLEM P2: nobody took the gun seat of a waiting driver")
	end
end)

report("PADS", before)

--------------------------------------------------------------------------------
-- P4 ROAM: the map's own parked vehicles, 20 bots put down beside them
--------------------------------------------------------------------------------

run("P4 ROAM", function()
	BotService.Clear()
	arena:Destroy()
	folder:Destroy()
	task.wait(1)
	local parked = {}
	local vehiclesFolder = info.map:FindFirstChild("Vehicles")
	for _, model in ipairs(vehiclesFolder and vehiclesFolder:GetChildren() or {}) do
		if model:IsA("Model") and model.PrimaryPart then
			table.insert(parked, model)
		end
	end
	say("P4 %d parked vehicles on %s", #parked, MAP_ID)
	if #parked == 0 then
		say("PROBLEM P4: no parked vehicles to ride")
		return
	end
	local bots = BotService.Spawn(ROAM_BOTS, function(index)
		local model = parked[(index - 1) % #parked + 1]
		local p = model.PrimaryPart.Position
		return CFrame.new(p + Vector3.new(14, 4, 0))
	end, function() end)
	local roamBefore = statsCopy()
	BotService.Start()
	local peakDrivers, samples, riding, driving, flipped = 0, 0, 0, 0, 0
	local t0 = os.clock()
	while os.clock() - t0 < ROAM_SECONDS do
		task.wait(1)
		samples += 1
		local drivers = 0
		for _, bot in ipairs(bots) do
			local ride = bot.ride
			if ride then
				riding += 1
				if ride.role == "driver" then
					drivers += 1
					driving += 1
					local chassis = ride.drive and ride.drive.chassis
					if chassis and chassis.CFrame.UpVector.Y < 0.3 then
						flipped += 1
					end
				end
			end
		end
		peakDrivers = math.max(peakDrivers, drivers)
	end
	say("P4 %d s: bot-seconds riding %d, driving %d, peak drivers %d (cap %d), flipped driver-seconds %d",
		samples, riding, driving, peakDrivers, MatchConfig.BotDriversMax, flipped)
	if peakDrivers > MatchConfig.BotDriversMax then
		say("PROBLEM P4: more drivers than BotDriversMax")
	end
	report("ROAM", roamBefore)
	local stats = BotService.Stats or {}
	say("P4 think worst tick %.2f ms", (stats.maxTick or 0) * 1000)
end)

BotService.Clear()
say("done")
