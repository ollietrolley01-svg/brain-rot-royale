-- Roadkill momentum probe (Oliver 09-24: "make vehicles keep their momentum when they do a roadkill"),
-- measured with real physics: Run mode (RunService:Run(), as tools/mapvehicle_physics_probe.lua does),
-- a car driven by a seated bot rig at a standing bot rig on a flat slab, far from everything.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/roadkill_momentum_probe.lua -WaitSeconds 900
--
-- Every row is run twice over: with the momentum rule (RoadkillPass) and with it switched off
-- (VehicleService.RoadkillPass = false: the old behaviour, no pass, no throw, no crash grace), and
-- against a CONTROL run with nobody in the road, so the car's own acceleration and drag are taken out:
--   loss = (control speed - speed) / control speed, both read when the car's middle is PASS_BY studs
--   past where the body stood.
-- Rows: a light car (TralalaGT) and an armoured one (CameloCarrier) at 30 and 55 studs/s into a live
-- body; the same at 55 over a fresh ragdoll; a lethal hit (where the body goes); and a nudge under the
-- floor (8 studs/s: no damage, nothing let through).
--
-- What it cannot measure: a player's client simulating the car and another player's client the body.
-- Here the server simulates both (a bot's car into a bot); the client half runs the same RoadkillPass
-- (tools/roadkill_momentum_check.py proves its logic), but what a real network does to it needs two
-- real clients.
--
-- Lines start "[ROADKILL]". "PROBLEM" lines are findings; "FAULT" lines are planted faults proving
-- the reading above them can fail.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(modules:WaitForChild("VehicleService"))
local Combatants = require(modules:WaitForChild("Combatants"))
local CombatService = require(modules:WaitForChild("CombatService"))
local DeathFxService = nil
do
	local ok, module = pcall(require, modules:WaitForChild("DeathFxService"))
	DeathFxService = ok and module or nil
end

local TAG = "[ROADKILL]"
local CX, CZ = 2600, 2600
local LANE_LENGTH = 700
local RUNUP = 150
local GAP_STOP = 14 -- studs from the car's middle to the body when the run-up stops writing its speed
local PASS_BY = 15 -- studs past the body's spot where the speed after is read

local function out(format, ...)
	if select("#", ...) > 0 then
		print(TAG .. " " .. string.format(format, ...))
	else
		print(TAG .. " " .. format)
	end
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(3)
out("start: Run mode %s", tostring(RunService:IsRunning()))

local folder = Instance.new("Folder")
folder.Name = "RoadkillMomentumProbe"
folder.Parent = workspace

-- This copy of CombatService's deaths go to this copy of DeathFxService (the body's ragdoll and throw).
if DeathFxService then
	CombatService.OnDeathFx = DeathFxService.OnDeath
end
VehicleService.Start()

local lane = 0
local function newLane()
	lane += 1
	local x = CX + lane * 60
	local slab = Instance.new("Part")
	slab.Name = "Road" .. lane
	slab.Anchored = true
	slab.Size = Vector3.new(40, 4, LANE_LENGTH)
	slab.Position = Vector3.new(x, -2, CZ)
	slab.Material = Enum.Material.Asphalt
	slab.Parent = folder
	return x, slab
end

local function makeRig(name, position)
	for _ = 1, 5 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			model.Name = name
			model.Parent = folder
			model:PivotTo(CFrame.new(position))
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			humanoid.BreakJointsOnDeath = false
			local token = { isBot = true, name = name, character = model }
			Combatants.Register(model, token)
			-- What MatchService does for every combatant: a death goes to CombatService.HandleDeath
			-- (the kill credit, and the body's effect: DeathFxService.OnDeath, which reads RoadkillThrow).
			humanoid.Died:Connect(function()
				pcall(CombatService.HandleDeath, token)
			end)
			return model, humanoid
		end
		task.wait(0.4)
	end
	return nil
end

local function passCount(model)
	local count = 0
	for _, item in ipairs(model:GetDescendants()) do
		if item:IsA("NoCollisionConstraint") and item.Name == "RoadkillPass" then
			count += 1
		end
	end
	return count
end

-- One run. opts: modelId, speed, body ("live" | "corpse" | "lethal" | "wall" | nil), momentum, nudge.
local function run(opts)
	-- (Not `opts.momentum and nil or false`: that is always false.)
	if opts.momentum then
		VehicleService.RoadkillPass = nil
	else
		VehicleService.RoadkillPass = false
	end
	local x, slab = newLane()
	local startZ = CZ + 300
	-- A nudge is a crawl, so it starts close.
	local bodyZ = startZ - (opts.nudge and 40 or RUNUP)
	local model = VehicleService.Create(folder, Vector3.new(x, 4, startZ), 0, "car", { model = opts.modelId })
	local chassis = model:FindFirstChild("Chassis")
	local seat = model:FindFirstChildOfClass("VehicleSeat")
	local result = { ok = false }
	local driver, driverHumanoid = makeRig("ProbeDriver", seat.Position + Vector3.new(0, 3, 0))
	local victim, victimHumanoid, wall = nil, nil, nil
	local cleanup = function()
		VehicleService.RoadkillPass = nil
		for _, item in ipairs({ model, driver, victim, wall, slab }) do
			if item then
				item:Destroy()
			end
		end
	end
	if not driver then
		cleanup()
		return result, "no driver rig"
	end
	seat:Sit(driverHumanoid)
	task.wait(1.2)
	if opts.body == "wall" then
		wall = Instance.new("Part")
		wall.Name = "PlantedWall"
		wall.Anchored = true
		wall.Size = Vector3.new(10, 6, 2)
		wall.Position = Vector3.new(x, 3, bodyZ)
		wall.Parent = folder
	elseif opts.body then
		victim, victimHumanoid = makeRig("ProbeVictim", Vector3.new(x, 3.2, bodyZ))
		if not victim then
			cleanup()
			return result, "no victim rig"
		end
		if opts.body == "lethal" then
			victimHumanoid.Health = 30
		end
	end
	task.wait(1)
	local vehicleHealthBefore = model:GetAttribute("VehicleHealth")
	local victimHealthBefore = victimHumanoid and victimHumanoid.Health or 0
	local victimFrom = victim and victim:GetPivot().Position or nil

	local throttle = RunService.Heartbeat:Connect(function()
		seat.ThrottleFloat = opts.nudge and 0 or 1
		seat.SteerFloat = 0
	end)
	-- The run-up: the speed written each frame until GAP_STOP, then the car is on its own.
	local killed = false
	local started = os.clock()
	local pre = nil
	while os.clock() - started < 15 do
		local v = chassis.AssemblyLinearVelocity
		local gap = chassis.Position.Z - bodyZ
		if opts.body == "corpse" and not killed and gap < opts.speed * 1.6 + GAP_STOP then
			-- A fresh body: dead about a second and a half before the car arrives, as a ragdoll lies.
			killed = true
			victimHumanoid.Health = 0
			if DeathFxService then
				DeathFxService.Apply(victim, "ragdoll", Vector3.new(0, 2, 0))
			end
		end
		if gap < GAP_STOP then
			pre = flat(v)
			break
		end
		chassis.AssemblyLinearVelocity = Vector3.new(0, v.Y, -opts.speed)
		RunService.Heartbeat:Wait()
	end
	local nudged = 0
	if pre and opts.nudge then
		-- Under the floor the car is held at its crawl INTO the body for a second and a half.
		local pushing = os.clock()
		while os.clock() - pushing < 1.5 do
			local v = chassis.AssemblyLinearVelocity
			chassis.AssemblyLinearVelocity = Vector3.new(0, v.Y, -opts.speed)
			nudged = math.max(nudged, passCount(model))
			RunService.Heartbeat:Wait()
		end
	end
	if not pre then
		throttle:Disconnect()
		cleanup()
		return result, "the run-up never reached the body"
	end
	-- Through it: the lowest speed, the most constraints seen, and the speed PASS_BY studs past.
	local low, post, most = pre, nil, nudged
	started = os.clock()
	while os.clock() - started < 3 do
		RunService.Heartbeat:Wait()
		local speed = flat(chassis.AssemblyLinearVelocity)
		low = math.min(low, speed)
		most = math.max(most, passCount(model))
		if chassis.Position.Z < bodyZ - PASS_BY then
			post = speed
			break
		end
	end
	local stuck = post == nil
	post = post or flat(chassis.AssemblyLinearVelocity)
	throttle:Disconnect()
	task.wait(0.6)
	result.ok = true
	result.pre, result.post, result.low, result.stuck, result.most = pre, post, low, stuck, most
	result.vehicleBefore, result.vehicleAfter = vehicleHealthBefore, model:GetAttribute("VehicleHealth")
	if victim then
		local root = victim:FindFirstChild("HumanoidRootPart") or victim.PrimaryPart
		local moved = (root and root.Position or victimFrom) - victimFrom
		result.victimBefore, result.victimAfter = victimHealthBefore, victimHumanoid.Health
		-- Travel is -Z: forward is -moved.Z.
		result.forward, result.up, result.side = -moved.Z, moved.Y, moved.X
		result.throwMark = victim:GetAttribute("RoadkillThrow")
	end
	cleanup()
	return result
end

local function row(label, opts, control)
	local ok, result, why = pcall(run, opts)
	if not ok then
		out("PROBLEM %s: the run failed: %s", label, tostring(result))
		return nil
	end
	if not result.ok then
		out("PROBLEM %s: %s", label, tostring(why))
		return nil
	end
	local loss = control and (control.post - result.post) / control.post * 100 or 0
	local text = string.format("%s: pre %.1f post %.1f%s low %.1f%s | vehicle hp %s -> %s | pass constraints %d",
		label, result.pre, result.post, control and string.format(" control %.1f loss %.1f%%", control.post, loss) or "",
		result.low, result.stuck and " STUCK (never got past)" or "",
		tostring(result.vehicleBefore), tostring(result.vehicleAfter), result.most)
	if result.victimBefore then
		text ..= string.format(" | victim hp %.0f -> %.0f, moved forward %.1f up %.1f side %.1f",
			result.victimBefore, result.victimAfter, result.forward, result.up, result.side)
	end
	out("ROW %s", text)
	result.loss = loss
	return result
end

local MODELS = { "TralalaGT", "CameloCarrier" }
local summary = {}
for _, modelId in ipairs(MODELS) do
	local controls = {}
	for _, speed in ipairs({ 30, 55 }) do
		controls[speed] = row(string.format("%s %d control (nobody in the road)", modelId, speed),
			{ modelId = modelId, speed = speed, momentum = true })
	end
	for _, speed in ipairs({ 30, 55 }) do
		for _, momentum in ipairs({ false, true }) do
			local label = string.format("%s %d live body, momentum %s", modelId, speed, momentum and "ON" or "off")
			local r = row(label, { modelId = modelId, speed = speed, body = "live", momentum = momentum }, controls[speed])
			if r then
				table.insert(summary, { label = label, r = r, momentum = momentum })
				if momentum then
					if r.loss > 5 then
						out("PROBLEM %s: lost %.1f%% of its speed (want a few percent at most)", label, r.loss)
					end
					if r.vehicleAfter ~= r.vehicleBefore then
						out("PROBLEM %s: the vehicle's health changed %s -> %s (a roadkill is never a crash)", label,
							tostring(r.vehicleBefore), tostring(r.vehicleAfter))
					end
					if not (r.victimAfter < r.victimBefore) then
						out("PROBLEM %s: the body took no damage", label)
					end
					if not (r.forward > 3) then
						out("PROBLEM %s: the body was not thrown along the direction of travel (forward %.1f)", label, r.forward)
					end
				end
			end
		end
	end
	for _, momentum in ipairs({ false, true }) do
		local label = string.format("%s 55 over a fresh ragdoll, momentum %s", modelId, momentum and "ON" or "off")
		local r = row(label, { modelId = modelId, speed = 55, body = "corpse", momentum = momentum }, controls[55])
		if r and momentum and r.loss > 1.5 then
			out("PROBLEM %s: a corpse cost %.1f%% of its speed (want nothing)", label, r.loss)
		end
	end
	local lethal = row(string.format("%s 55 lethal hit, momentum ON", modelId),
		{ modelId = modelId, speed = 55, body = "lethal", momentum = true }, controls[55])
	if lethal and not (lethal.victimAfter <= 0 and lethal.forward > 3) then
		out("PROBLEM %s lethal: dead %s, the body went forward %.1f", modelId, tostring(lethal.victimAfter <= 0), lethal.forward or 0)
	end
	local nudge = row(string.format("%s 8 (under the floor) into a live body, momentum ON", modelId),
		{ modelId = modelId, speed = 8, body = "live", momentum = true, nudge = true })
	if nudge and (nudge.victimAfter < nudge.victimBefore or nudge.most > 0) then
		out("PROBLEM %s nudge: under the floor the body took %.0f damage and %d constraints were made", modelId,
			nudge.victimBefore - nudge.victimAfter, nudge.most)
	end
	-- PLANTED FAULT: an anchored wall where the body stood. The same reading must show a big loss (and
	-- crash damage), or the rows above prove nothing.
	local wall = row(string.format("FAULT %s 55 into a planted wall, momentum ON", modelId),
		{ modelId = modelId, speed = 55, body = "wall", momentum = true }, controls[55])
	if wall then
		out("FAULT %s wall: loss %.1f%% (want far more than a body's), vehicle hp %s -> %s (want less)", modelId, wall.loss,
			tostring(wall.vehicleBefore), tostring(wall.vehicleAfter))
	end
end

folder:Destroy()
out("done: %d vehicles still registered in this copy of VehicleService", VehicleService.Count())
