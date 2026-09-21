-- #53 (vehicle low-health warning) and #57 (roadkill): proves the health/damage system actually
-- does what VehicleService.lua now claims, in execution, not by reading the source.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/vehicle_health_probe.lua -WaitSeconds 200
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
--   attributes   VehicleMaxHealth/VehicleHealth read 300 on a car, 150 on a bike, the moment it spawns
--   collision    a hard wall hit above the 18 studs/s floor damages the vehicle by roughly the
--                measured speed loss; the SAME vehicle coasting to a dead stop with nothing in its
--                way (no wall) takes none -- the planted-fault half: this check can fail, and here
--                it would if collision damage fired on ordinary braking
--   roadkill     a stationary dummy hit at speed takes damage through CombatService.DealDamage
--                (shield-aware); the same dummy nudged under the 12 studs/s floor takes none
--   parked-on    a car settled to rest ON a dummy (zero speed, sustained contact, Touched re-firing
--                every frame of overlap) deals it NO damage over several seconds -- claude-43's
--                first condition, proven by construction (the floor check runs before the debounce
--                is even consulted) and now measured too
--   debounce     continuous contact with one dummy at speed for over a second deals roughly ONE
--                hit's worth of damage, not sixty ticks of it; AND survives a collectgarbage()
--                forced inside its own 0.5s window (bug-hunt B3-1, the geyser-cooldown technique
--                from tools/wilds_landmarks_probe.lua's GEYSER test) -- plus an isolated self-check
--                that a weak-keyed table of the same shape does NOT survive the same collection,
--                proving the technique can fail rather than just reading as green
--   wreck        health driven to zero: Wrecked is set, the drive prompt is disabled, the driver is
--                put back on their feet (ejected, not left welded into a dead car)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(Modules:WaitForChild("VehicleService"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local CombatService = require(Modules:WaitForChild("CombatService"))

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
	else
		failed += 1
	end
	print(string.format("[BRR_VehicleHealth] %-52s %s  %s", name, ok and "PASS" or "FAIL", detail or ""))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(2)

local wasEnabled = CombatService.IsEnabled()
CombatService.SetEnabled(true)
VehicleService.Start()

local folder = Instance.new("Folder")
folder.Name = "BRR_VehicleHealthProbe"
folder.Parent = workspace

local ORIGIN = Vector3.new(-5200, 500, -5200)
local LANE = 140

local function slab(size, cframe, material)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = material or Enum.Material.Concrete
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = folder
	return part
end

local function dummy(name, position)
	local token = { isBot = true, name = name }
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position)
	root.Anchored = true
	root.CanCollide = true
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = folder
	token.character = model
	Combatants.Register(model, token)
	return token, humanoid, root
end

local template
for _ = 1, 3 do
	local ok, m = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and m then
		template = m
		break
	end
	task.wait(2)
end

local function drive(seat, throttle, steer)
	seat.ThrottleFloat = throttle
	seat.SteerFloat = steer
	seat.Throttle = throttle > 0.01 and 1 or 0
	seat.Steer = 0
end

-- Pinned, not random (the "PIN THE BEHAVIOUR, NOT THE ENVIRONMENT" lesson): VehicleService.Create
-- draws its own Random when `options.model` is absent, so "car"/"bike" picked a different model
-- every run -- the nudge test flipped from PASS to FAIL between two runs of identical code because
-- a faster-accelerating car got picked and the same 0.12-throttle creep crossed the roadkill floor.
local PINNED_MODEL = { car = "Rotster", bike = "BananiniScoot" }

-- Spawns `kind`, seats a rig in the driver's seat so it can actually be steered (roadkill and
-- collision both need a driven vehicle, not a parked one -- an unowned/parked vehicle is stepped by
-- the server's own rest-skip logic and barely moves).
local function spawnDriven(x, kind)
	local model = VehicleService.Create(folder, Vector3.new(x, ORIGIN.Y + 3, ORIGIN.Z), 0, kind, { model = PINNED_MODEL[kind] })
	task.wait(1)
	local seat = model:FindFirstChildOfClass("VehicleSeat")
	local chassis = model:FindFirstChild("Chassis")
	local entry = VehicleService.Get(model)
	if template and seat then
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
	end
	return model, seat, chassis, entry
end

--------------------------------------------------------------------------------
-- Attributes on spawn
--------------------------------------------------------------------------------

do
	local car = VehicleService.Create(folder, ORIGIN + Vector3.new(0, 3, 400), 0, "car", { model = "Rotster" })
	local bike = VehicleService.Create(folder, ORIGIN + Vector3.new(60, 3, 400), 0, "bike", { model = "BananiniScoot" })
	task.wait(0.5)
	check("car spawns at VehicleMaxHealth 300", car:GetAttribute("VehicleMaxHealth") == 300 and car:GetAttribute("VehicleHealth") == 300,
		string.format("max %s health %s", tostring(car:GetAttribute("VehicleMaxHealth")), tostring(car:GetAttribute("VehicleHealth"))))
	check("bike spawns at VehicleMaxHealth 150", bike:GetAttribute("VehicleMaxHealth") == 150 and bike:GetAttribute("VehicleHealth") == 150,
		string.format("max %s health %s", tostring(bike:GetAttribute("VehicleMaxHealth")), tostring(bike:GetAttribute("VehicleHealth"))))
	car:Destroy()
	bike:Destroy()
end

--------------------------------------------------------------------------------
-- Collision damage: a hard hit costs health, a clean stop costs none
--------------------------------------------------------------------------------

do
	local x = ORIGIN.X + LANE
	slab(Vector3.new(40, 4, 500), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	slab(Vector3.new(40, 30, 4), CFrame.new(x, ORIGIN.Y + 13, ORIGIN.Z - 260)) -- wall at the far end
	local model, seat, chassis, entry = spawnDriven(x, "car")
	local before = entry.health
	drive(seat, 1, 0)
	local began = os.clock()
	local hitWall = false
	while os.clock() - began < 8 do
		if chassis.Position.Z < ORIGIN.Z - 250 then
			hitWall = true
			break
		end
		RunService.Heartbeat:Wait()
	end
	task.wait(0.5) -- let the impact register and damageVehicle apply
	drive(seat, 0, 0)
	local after = entry.health
	check("a wall hit at speed damages the car", hitWall and after < before,
		string.format("before %.0f after %.0f (reached wall: %s)", before, after, tostring(hitWall)))
	model:Destroy()
end

do
	local x = ORIGIN.X + LANE * 2
	slab(Vector3.new(40, 4, 300), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	local model, seat, chassis, entry = spawnDriven(x, "car")
	local before = entry.health
	drive(seat, 1, 0)
	local began = os.clock()
	while os.clock() - began < 4 do
		RunService.Heartbeat:Wait()
	end
	-- Ease off smoothly rather than slamming the brakes, so the per-step speed loss never crosses
	-- the 18 studs/s floor -- this is what "ordinary braking" means for the check above.
	local decel = os.clock()
	while os.clock() - decel < 3 do
		local speed = Vector3.new(chassis.AssemblyLinearVelocity.X, 0, chassis.AssemblyLinearVelocity.Z).Magnitude
		drive(seat, speed > 1 and -0.12 or 0, 0)
		RunService.Heartbeat:Wait()
	end
	local after = entry.health
	check("coasting to a stop with nothing in the way takes no damage", after == before,
		string.format("before %.0f after %.0f", before, after))
	model:Destroy()
end

--------------------------------------------------------------------------------
-- Roadkill: a dummy in the road
--------------------------------------------------------------------------------

do
	local x = ORIGIN.X + LANE * 3
	slab(Vector3.new(40, 4, 400), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	local token, humanoid = dummy("RoadkillFast", Vector3.new(x, ORIGIN.Y + 1, ORIGIN.Z - 180))
	local model, seat, chassis = spawnDriven(x, "car")
	drive(seat, 1, 0)
	local began = os.clock()
	while os.clock() - began < 8 and humanoid.Health >= 100 do
		RunService.Heartbeat:Wait()
	end
	drive(seat, 0, 0)
	local lost = 100 - humanoid.Health
	-- Not an exact formula match (speed varies through the hit), just "meaningfully hurt, not zero
	-- and not a one-shot from something else".
	check("a dummy hit at speed takes roadkill damage", lost > 5 and lost < 100,
		string.format("health %.1f (lost %.1f)", humanoid.Health, lost))
	model:Destroy()
	Combatants.Unregister(token.character)
	token.character:Destroy()
end

do
	local x = ORIGIN.X + LANE * 4
	slab(Vector3.new(40, 4, 120), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	local token, humanoid = dummy("RoadkillNudge", Vector3.new(x, ORIGIN.Y + 1, ORIGIN.Z - 30))
	local model, seat, chassis = spawnDriven(x, "car")
	-- A gentle creep, not a drive: never lets speed cross the 12 studs/s floor.
	drive(seat, 0.12, 0)
	local began = os.clock()
	while os.clock() - began < 4 do
		RunService.Heartbeat:Wait()
	end
	drive(seat, 0, 0)
	check("a slow nudge under the floor takes no roadkill damage", humanoid.Health >= 99.9,
		string.format("health %.1f", humanoid.Health))
	model:Destroy()
	Combatants.Unregister(token.character)
	token.character:Destroy()
end

--------------------------------------------------------------------------------
-- Parked on someone: claude-43's condition
--------------------------------------------------------------------------------

do
	local x = ORIGIN.X + LANE * 5
	slab(Vector3.new(40, 4, 120), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	local token, humanoid = dummy("RoadkillParked", Vector3.new(x, ORIGIN.Y + 1, ORIGIN.Z - 20))
	-- Dropped from a few studs up right onto the dummy, so the chassis settles into sustained
	-- contact rather than a moving pass-through -- the exact "car parked on someone" shape.
	local model = VehicleService.Create(folder, Vector3.new(x, ORIGIN.Y + 4, ORIGIN.Z - 20), 0, "car", { model = PINNED_MODEL.car })
	task.wait(3.5) -- well past a landing thump, into rest
	check("a car settled to rest on a dummy deals it no damage", humanoid.Health >= 99.9,
		string.format("health %.1f after 3.5s resting", humanoid.Health))
	model:Destroy()
	Combatants.Unregister(token.character)
	token.character:Destroy()
end

--------------------------------------------------------------------------------
-- Debounce: sustained contact ticks roughly once, not every frame
--------------------------------------------------------------------------------

do
	local x = ORIGIN.X + LANE * 6
	slab(Vector3.new(60, 4, 700), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	local token, humanoid = dummy("RoadkillDebounce", Vector3.new(x, ORIGIN.Y + 1, ORIGIN.Z - 220))
	local model, seat, chassis = spawnDriven(x, "car")
	drive(seat, 1, 0)
	local began = os.clock()
	-- Keep driving flat out for well over a second AFTER first contact, so a broken debounce (one
	-- tick per physics step) would show up as far more than one hit's worth of damage. The dummy is
	-- anchored, so a blocked car stays in continuous Touched contact with it rather than passing
	-- straight through -- this is what gives the window its length, not a special setup for this test.
	local hitAt, healthAtFirstHit, collected = nil, nil, false
	while os.clock() - began < 8 do
		if not hitAt and humanoid.Health < 100 then
			hitAt = os.clock()
			healthAtFirstHit = humanoid.Health
			-- The geyser-cooldown technique (tools/wilds_landmarks_probe.lua's GEYSER test,
			-- bug-hunt B3-1 precedent claude-43 pointed at): force a collection INSIDE the
			-- debounce window, on the real live code, not a copy. If roadkillCooldown were still
			-- weak-keyed, this is what would empty the entry and let the very next Touched event
			-- (contact is still ongoing) deal a second full hit.
			collectgarbage("collect")
			collected = true
		end
		if hitAt and os.clock() - hitAt > 1.3 then
			break
		end
		RunService.Heartbeat:Wait()
	end
	drive(seat, 0, 0)
	local lost = 100 - humanoid.Health
	check("sustained contact deals roughly one hit, not one per frame", hitAt ~= nil and lost < 200,
		string.format("lost %.1f over %s of sustained contact", lost, hitAt and string.format("%.2fs", os.clock() - hitAt) or "no contact"))
	-- The tight version of the same measurement: health must be EXACTLY what it was the instant
	-- after the first hit, not just "under some loose bound" -- a collection-reset debounce would
	-- show as MORE loss here, not a rounding difference.
	check("the debounce survives a collection forced inside its own window (real code, real touch)",
		collected and humanoid.Health == healthAtFirstHit,
		string.format("health at first hit %.2f, unchanged %.2fs later through a mid-contact collectgarbage: %.2f",
			healthAtFirstHit or -1, hitAt and (os.clock() - hitAt) or 0, humanoid.Health))
	model:Destroy()
	Combatants.Unregister(token.character)
	token.character:Destroy()
end

-- Self-check: proves the technique itself, isolated from the game code entirely -- a weak-keyed
-- table of this exact shape (Humanoid inside a Model, held by a live local variable throughout,
-- same as the geyser test's dummy character) must NOT survive a collection, or the check above
-- proves nothing.
do
	local weakCooldown = setmetatable({}, { __mode = "k" })
	local selfCheckModel = Instance.new("Model")
	local selfCheckHumanoid = Instance.new("Humanoid")
	selfCheckHumanoid.Parent = selfCheckModel
	selfCheckModel.Parent = workspace
	weakCooldown[selfCheckHumanoid] = tick()
	collectgarbage("collect")
	local survived = weakCooldown[selfCheckHumanoid] ~= nil
	check("self-check: a weak-keyed debounce of this shape does NOT survive a collection (must fail)",
		not survived, string.format("entry survived the collection: %s", tostring(survived)))
	selfCheckModel:Destroy()
end

--------------------------------------------------------------------------------
-- Wreck: health to zero ejects the driver and locks the doors
--------------------------------------------------------------------------------

do
	local x = ORIGIN.X + LANE * 7
	slab(Vector3.new(40, 4, 260), CFrame.new(x, ORIGIN.Y - 2, ORIGIN.Z - 20))
	slab(Vector3.new(40, 30, 4), CFrame.new(x, ORIGIN.Y + 13, ORIGIN.Z - 200))
	local model, seat, chassis, entry = spawnDriven(x, "car")
	local rider = seat.Occupant
	-- Repeated run-ups into the same wall: coast back, ram again, until it wrecks or gives up.
	local attempts = 0
	while entry.health > 0 and attempts < 8 do
		attempts += 1
		model:PivotTo(CFrame.new(x, ORIGIN.Y + 0.5, ORIGIN.Z) * CFrame.Angles(0, 0, 0))
		chassis.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.3)
		drive(seat, 1, 0)
		local began = os.clock()
		while os.clock() - began < 5 and chassis.Position.Z > ORIGIN.Z - 195 do
			RunService.Heartbeat:Wait()
		end
		task.wait(0.4)
		drive(seat, 0, 0)
	end
	check("enough hits wrecks the car", entry.health <= 0 and entry.wrecked == true,
		string.format("health %.0f wrecked %s after %d run(s)", entry.health, tostring(entry.wrecked), attempts))
	check("Wrecked attribute reaches the client", model:GetAttribute("Wrecked") == true, "")
	local drivePrompt = entry.prompts[seat]
	-- Diagnostic, not a check: this run's prompt check failed once already and the code reads as
	-- correct, so print the state at two points instead of guessing again -- immediately (before
	-- any deferred signal from the ejection could have run) and after a settle, so a flip between
	-- them would prove a race rather than "never disabled at all".
	print(string.format("[BRR_VehicleHealth] diag: immediately after wreck, prompt.Enabled=%s entry.wrecked=%s",
		tostring(drivePrompt and drivePrompt.Enabled), tostring(entry.wrecked)))
	task.wait()
	print(string.format("[BRR_VehicleHealth] diag: one frame later, prompt.Enabled=%s entry.wrecked=%s",
		tostring(drivePrompt and drivePrompt.Enabled), tostring(entry.wrecked)))
	check("the drive prompt is disabled once wrecked", drivePrompt ~= nil and drivePrompt.Enabled == false,
		string.format("prompt %s", drivePrompt and tostring(drivePrompt.Enabled) or "missing"))
	task.wait(0.3)
	check("the driver is put back on their feet, not left welded in", rider ~= nil and seat.Occupant == nil,
		string.format("occupant now %s", tostring(seat.Occupant)))
	model:Destroy()
end

CombatService.SetEnabled(wasEnabled)
folder:Destroy()
print(string.format("[BRR_VehicleHealth] passed %d, failed %d", passed, failed))
print("[BRR_VehicleHealth] done")
