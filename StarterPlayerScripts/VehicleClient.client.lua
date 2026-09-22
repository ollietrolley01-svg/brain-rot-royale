-- The driver's side of vehicles, and the moving parts of every vehicle you can see.
--
-- While you drive, the server hands you the chassis's physics and this script steps the shared
-- VehicleDynamics on your machine every frame, so the car answers the moment you press a key. If
-- the server takes it back for a moment (after a blast, or because something looked wrong) the
-- model carries ServerControl and this holds off.
--
-- For every vehicle near you, yours or anyone else's, it animates what moves: wheels bob, steer
-- and spin, a bike's fork turns and slides, its swingarm swings, a car's steering wheel turns. All
-- of it is Motor6D.Transform set locally from local rays, so nothing extra crosses the network.
-- Riders are posed the same way: hands on the bars or the wheel, feet on the pegs.
--
-- Controls while driving: W/S or the triggers to drive and brake, A/D or the stick to steer, Shift
-- (L1, or the on-screen button) for the handbrake, Space to get out.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleWreckFx = require(Shared:WaitForChild("VehicleWreckFx"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- #60 ("let me zoom out more when sitting in the vehicles"): the stock camera's default zoom room
-- (0.5..20 studs) is tight for a 14.6-stud truck seen from outside. Widened on entry, restored on
-- exit. CombatClient's own zoom pin (its Heartbeat loop, `pinCameraZoom(inCombat())`) used to fight
-- this every frame during a live match regardless of InVehicle -- claude-43 is routing a one-line fix
-- there (`pinCameraZoom(not player:GetAttribute("InVehicle") and inCombat())`) so this can hold.
local VEHICLE_MAX_ZOOM = 55
local VEHICLE_MIN_ZOOM = 6
local savedMinZoom, savedMaxZoom = nil, nil

local ANIMATE_DISTANCE = 320
local FULL_RATE_DISTANCE = 120
local POSE_DISTANCE = 200
local ENGINE_DISTANCE = 150
local FLIP_AFTER = 2.0
-- Engine pitch from a standstill to top speed, and how much of the loop you hear when it idles.
local ENGINE_PITCH_AT_TOP = 2.5
local ENGINE_IDLE_VOLUME = 0.45
-- The dial says KM/H, so it shows km/h: a stud is 0.28 m, so studs/s * 0.28 * 3.6 is almost exactly
-- the speed itself. A car at 100 studs/s reads 101, and a sprinting player would read 26.
local DISPLAY_SCALE = 1.008
-- #84 jolt reporting: see the Stepped connection below for the reasoning behind the number.
local JOLT_THRESHOLD = 20
local JOLT_REPORT_EVERY = 1

local rigs = {}          -- model -> rig (false while its parts are still streaming in)
local driving = nil      -- { model, rig, seat }
local handbrake = false
local frameCount = 0

--------------------------------------------------------------------------------
-- Finding vehicles
--------------------------------------------------------------------------------

local function track(model)
	if rigs[model] ~= nil or not model:GetAttribute("VehicleModel") then
		return
	end
	rigs[model] = false
	local pending = false
	local function rebuild()
		pending = false
		if model.Parent then
			rigs[model] = VehicleDynamics.Rig(model, true) or false
		end
	end
	rebuild()
	-- Streaming can deliver a vehicle a piece at a time: build again when a joint or force arrives.
	model.DescendantAdded:Connect(function(descendant)
		if not pending and (descendant:IsA("Motor6D") or descendant:IsA("VectorForce") or descendant:IsA("AlignOrientation")) then
			pending = true
			task.defer(rebuild)
		end
	end)
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			local rig = rigs[model]
			if rig and rig.engineLoop then
				rig.engineLoop:Stop()
				rig.engineLoop = nil
			end
			rigs[model] = nil
		end
	end)
end

local function watchFolder(folder)
	for _, child in ipairs(folder:GetChildren()) do
		track(child)
	end
	folder.ChildAdded:Connect(track)
end

local function watchMap(map)
	local vehicles = map:FindFirstChild("Vehicles")
	if vehicles then
		watchFolder(vehicles)
	end
	map.ChildAdded:Connect(function(child)
		if child.Name == "Vehicles" then
			watchFolder(child)
		end
	end)
end

if workspace:FindFirstChild("Map") then
	watchMap(workspace.Map)
end
workspace.ChildAdded:Connect(function(child)
	if child.Name == "Map" then
		watchMap(child)
	end
end)

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "VehicleHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -118)
panel.Size = UDim2.fromOffset(250, 78)
panel.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
panel.BackgroundTransparency = 0.25
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local nameLabel = Instance.new("TextLabel")
nameLabel.BackgroundTransparency = 1
nameLabel.Position = UDim2.fromOffset(14, 6)
nameLabel.Size = UDim2.new(1, -28, 0, 14)
nameLabel.Font = Enum.Font.GothamBold
nameLabel.TextSize = 12
nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.TextColor3 = Color3.fromRGB(170, 176, 190)
nameLabel.Text = ""
nameLabel.Parent = panel

local speedLabel = Instance.new("TextLabel")
speedLabel.BackgroundTransparency = 1
speedLabel.Position = UDim2.fromOffset(14, 18)
speedLabel.Size = UDim2.new(0.5, 0, 0, 38)
speedLabel.Font = Enum.Font.FredokaOne
speedLabel.TextScaled = true
speedLabel.TextXAlignment = Enum.TextXAlignment.Left
speedLabel.TextColor3 = Color3.fromRGB(245, 245, 250)
speedLabel.Text = "0"
speedLabel.Parent = panel

local unitLabel = Instance.new("TextLabel")
unitLabel.BackgroundTransparency = 1
unitLabel.Position = UDim2.new(0.5, -10, 0, 30)
unitLabel.Size = UDim2.new(0.5, 0, 0, 20)
unitLabel.Font = Enum.Font.GothamBold
unitLabel.TextScaled = true
unitLabel.TextXAlignment = Enum.TextXAlignment.Left
unitLabel.TextColor3 = Color3.fromRGB(170, 176, 190)
unitLabel.Text = "KM/H"
unitLabel.Parent = panel

local bar = Instance.new("Frame")
bar.Position = UDim2.fromOffset(14, 62)
bar.Size = UDim2.new(1, -28, 0, 6)
bar.BackgroundColor3 = Color3.fromRGB(56, 60, 72)
bar.BorderSizePixel = 0
bar.Parent = panel
local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(255, 196, 64)
fill.BorderSizePixel = 0
fill.Parent = bar

local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.AnchorPoint = Vector2.new(0.5, 1)
hint.Position = UDim2.new(0.5, 0, 1, -98)
hint.Size = UDim2.fromOffset(420, 18)
hint.Font = Enum.Font.GothamBold
hint.TextSize = 14
hint.TextColor3 = Color3.fromRGB(220, 224, 234)
hint.TextStrokeTransparency = 0.5
-- Naming a key a gamepad hasn't got is worse than saying nothing, so the hint follows the device
-- the player last used, as the world's key hints do.
local function refreshHint()
	local last = UserInputService:GetLastInputType()
	local pad = string.find(last.Name, "Gamepad", 1, true) ~= nil
	if last == Enum.UserInputType.Touch then
		hint.Text = "JUMP  get out     BRAKE  handbrake"
	elseif pad then
		hint.Text = "A  get out     L1  handbrake     R2/L2  drive"
	else
		hint.Text = "SPACE  get out     SHIFT  handbrake"
	end
end
refreshHint()
UserInputService.LastInputTypeChanged:Connect(refreshHint)
hint.Parent = gui

-- #53: low-health / wrecked warning. Reads VehicleHealth/VehicleMaxHealth/Wrecked straight off the
-- driven model -- the server's own numbers (VehicleService.lua), never a client-side copy of them.
local healthWarning = Instance.new("TextLabel")
healthWarning.BackgroundTransparency = 1
healthWarning.AnchorPoint = Vector2.new(0.5, 1)
healthWarning.Position = UDim2.new(0.5, 0, 1, -138)
healthWarning.Size = UDim2.fromOffset(260, 20)
healthWarning.Font = Enum.Font.GothamBold
healthWarning.TextSize = 15
healthWarning.TextStrokeTransparency = 0.3
healthWarning.Text = ""
healthWarning.Visible = false
healthWarning.Parent = gui

local function updateHealthWarning(model)
	if model:GetAttribute("Wrecked") then
		healthWarning.Visible = true
		healthWarning.Text = "VEHICLE WRECKED"
		healthWarning.TextColor3 = Color3.fromRGB(170, 172, 180)
		healthWarning.TextTransparency = 0
		return
	end
	local health, maxHealth = model:GetAttribute("VehicleHealth"), model:GetAttribute("VehicleMaxHealth")
	if type(health) ~= "number" or type(maxHealth) ~= "number" or maxHealth <= 0 or health / maxHealth > VehicleDynamics.LOW_HEALTH_SHARE then
		healthWarning.Visible = false
		return
	end
	healthWarning.Visible = true
	healthWarning.Text = "VEHICLE DAMAGED"
	healthWarning.TextColor3 = Color3.fromRGB(255, 90, 90)
	-- A slow pulse (about 1/3 Hz) reads as "warning" without being unreadable; tick() so it isn't
	-- tied to physics dt.
	healthWarning.TextTransparency = 0.15 + 0.35 * (0.5 + 0.5 * math.sin(tick() * 2))
end

--------------------------------------------------------------------------------
-- Driving
--------------------------------------------------------------------------------

local function setHandbrake(on)
	handbrake = on
	if driving and driving.seat then
		-- For this machine's own step only: an attribute set on a client doesn't replicate, so while
		-- the server holds the physics (ServerControl) it simply drives without the handbrake.
		driving.seat:SetAttribute("Handbrake", on or nil)
	end
end

local function onHandbrake(_, state)
	if not driving then
		return Enum.ContextActionResult.Pass
	end
	setHandbrake(state == Enum.UserInputState.Begin)
	return Enum.ContextActionResult.Sink
end

local function stopDriving()
	if not driving then
		return
	end
	if driving.skidLoop then
		driving.skidLoop:Stop()
		driving.skidLoop = nil
	end
	setHandbrake(false)
	if driving.rig and driving.rig.chassis.Parent and not driving.model:GetAttribute("ServerControl") then
		VehicleDynamics.Idle(driving.rig)
	end
	if savedMinZoom then
		player.CameraMinZoomDistance, player.CameraMaxZoomDistance = savedMinZoom, savedMaxZoom
		savedMinZoom, savedMaxZoom = nil, nil
	end
	driving = nil
	gui.Enabled = false
	ContextActionService:UnbindAction("VehicleHandbrake")
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

local function startDriving(model, seat)
	local rig = rigs[model] or VehicleDynamics.Rig(model, true)
	if not rig then
		-- The wheels may not have replicated yet. The server hands this client the chassis the moment
		-- it is sat in, so if nothing here steps it, nothing anywhere does: keep trying while the
		-- player stays in this seat rather than leaving them in a vehicle that won't move.
		task.spawn(function()
			local deadline = tick() + 5 -- wall clock, not os.clock() (CPU time): this waits on replication, a real-time thing
			while tick() < deadline do
				task.wait(0.1)
				local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
				if not humanoid or humanoid.SeatPart ~= seat or not model.Parent then
					return
				end
				if VehicleDynamics.Rig(model, true) then
					startDriving(model, seat)
					return
				end
			end
			warn(string.format("VehicleClient: %s never gave up a rig; it will sit there", model.Name))
		end)
		return
	end
	rigs[model] = rig
	driving = { model = model, rig = rig, seat = seat }
	local def = VehicleModels.Models[model:GetAttribute("VehicleModel")]
	nameLabel.Text = string.upper(def and def.displayName or "")
	gui.Enabled = true
	ContextActionService:BindActionAtPriority("VehicleHandbrake", onHandbrake, true, Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL1)
	ContextActionService:SetTitle("VehicleHandbrake", "BRAKE")
	pcall(ContextActionService.SetPosition, ContextActionService, "VehicleHandbrake", UDim2.new(1, -180, 1, -150))
	Sfx.Play("VehicleStart", 0.05)
	-- CombatClient stands its camera and mouse lock down while this is set. The server sets it too,
	-- and is the one that clears it, but waiting for that to come back down the wire leaves the
	-- player locked in first person for a moment after they sit down.
	player:SetAttribute("InVehicle", true)
	-- A VehicleSeat subject gives the default camera its vehicle mode: it swings in behind the car.
	camera.CameraSubject = seat
	savedMinZoom, savedMaxZoom = player.CameraMinZoomDistance, player.CameraMaxZoomDistance
	player.CameraMinZoomDistance = VEHICLE_MIN_ZOOM
	player.CameraMaxZoomDistance = VEHICLE_MAX_ZOOM
end

local function watchCharacter(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end
	local function update()
		local seat = humanoid.SeatPart
		if seat and seat:IsA("VehicleSeat") and seat.Parent and seat.Parent:GetAttribute("VehicleModel") then
			if not driving or driving.seat ~= seat then
				stopDriving()
				startDriving(seat.Parent, seat)
			end
			return
		end
		stopDriving()
	end
	humanoid:GetPropertyChangedSignal("SeatPart"):Connect(update)
	humanoid.Died:Connect(stopDriving)
	update()
end

if player.Character then
	task.spawn(watchCharacter, player.Character)
end
player.CharacterAdded:Connect(watchCharacter)

-- The step for a kind another tab registered, if it has one: `StepModule` names a ModuleScript in
-- ReplicatedStorage.Shared returning { Step = function(model, rig, input, dt) -> telemetry }. Looked
-- up once per module and remembered, including the "there isn't one" answer.
local stepModules = {}

local function sharedStep(model, rig, input, dt)
	local name = model:GetAttribute("StepModule")
	if type(name) ~= "string" then
		return nil
	end
	local module = stepModules[name]
	if module == nil then
		local found = Shared:FindFirstChild(name)
		local ok, loaded = pcall(function()
			return found and require(found) or false
		end)
		module = (ok and type(loaded) == "table" and type(loaded.Step) == "function") and loaded or false
		stepModules[name] = module
		if not module then
			warn(string.format("VehicleClient: %s names a step module %q that isn't there; driving it with the standard dynamics",
				model.Name, name))
		end
	end
	if not module then
		return nil
	end
	local ok, telemetry = pcall(module.Step, model, rig, input, dt)
	if not ok or type(telemetry) ~= "table" then
		if not stepModules[name .. "!warned"] then
			stepModules[name .. "!warned"] = true
			warn(string.format("VehicleClient: the step in %s failed (%s); falling back to the standard dynamics",
				name, tostring(telemetry)))
		end
		return nil
	end
	return telemetry
end

RunService.Stepped:Connect(function(_, dt)
	if not driving then
		return
	end
	local rig = driving.rig
	local model = driving.model
	if not rig.chassis.Parent or not model.Parent then
		stopDriving()
		return
	end
	local seat = driving.seat
	if model:GetAttribute("ServerControl") then
		-- The server has taken the wheel (a honesty check fired). Nothing here is stepping the
		-- tyres any more, so the skid it was making must not hang on.
		if driving.skidLoop then
			driving.skidLoop:Stop()
			driving.skidLoop = nil
		end
		return
	end
	VehicleDynamics.SetIgnore(rig, { player.Character })
	local input = {
		throttle = seat.ThrottleFloat,
		steer = seat.SteerFloat,
		handbrake = handbrake,
	}
	-- A kind registered by another tab brings its own step, in a module both this machine and the
	-- server run, so behaviour that must always apply (a hull held at the water surface, say) does
	-- not stop the moment a player sits down. It is called through a pcall and falls back to the
	-- dynamics if it is missing OR if it raises: a step that throws once a frame would otherwise
	-- leave the driver in a vehicle that does nothing at all.
	local telemetry = sharedStep(model, rig, input, dt)
	if not telemetry then
		telemetry = VehicleDynamics.Step(rig, input, dt)
	end
	if telemetry.flippedFor > FLIP_AFTER then
		VehicleDynamics.Right(rig)
	end

	-- Tyres at the limit hiss; landing after air time thumps.
	if telemetry.slip and telemetry.grounded > 0 then
		if not driving.skidLoop then
			local attachment = rig.chassis:FindFirstChild("EngineSound")
			driving.skidLoop = attachment and Sfx.Loop("VehicleSkid", attachment) or nil
		end
	elseif driving.skidLoop then
		driving.skidLoop:Stop()
		driving.skidLoop = nil
	end
	if telemetry.grounded == 0 then
		driving.airborneFor = (driving.airborneFor or 0) + dt
	else
		if (driving.airborneFor or 0) > 0.35 then
			Sfx.PlayAt("VehicleLand", rig.chassis.Position, 0.08)
		end
		driving.airborneFor = 0
	end

	local speed = math.abs(telemetry.forwardSpeed)
	speedLabel.Text = tostring(math.floor(speed * DISPLAY_SCALE + 0.5))
	fill.Size = UDim2.fromScale(math.clamp(speed / rig.handling.topSpeed, 0, 1), 1)
	updateHealthWarning(model)

	-- #84: measured on the runtest harness (no client, no network ownership) flat road is 0.00
	-- vertical velocity and even the worst seam-at-speed case peaked at 3.14 studs/s -- so a jump
	-- past JOLT_THRESHOLD in one step, on a REAL driving client, is either something the harness
	-- could already see (a bug worth fixing anyway) or the one thing it structurally cannot: a
	-- network ownership handoff. Reported so Oliver's next session produces a number, not an
	-- impression, per claude-43's ask -- the same shape as this project's other after-the-fact
	-- counters. ServerControl is sent along because a handoff is exactly what that attribute marks.
	local vy = rig.chassis.AssemblyLinearVelocity.Y
	if driving.lastVerticalVel then
		local jump = math.abs(vy - driving.lastVerticalVel)
		if jump > JOLT_THRESHOLD and (not driving.lastJoltReport or tick() - driving.lastJoltReport > JOLT_REPORT_EVERY) then
			driving.lastJoltReport = tick()
			Remotes.Event("VehicleJolt"):FireServer(jump, speed, model:GetAttribute("ServerControl") == true)
		end
	end
	driving.lastVerticalVel = vy
end)

--------------------------------------------------------------------------------
-- Sound
--------------------------------------------------------------------------------

-- One engine loop per vehicle you can hear, on an attachment at its chassis, pitched by road
-- speed. Sfx.Loop keeps only the nearest few audible, and stops any loop whose vehicle goes away.
local function updateEngine(model, rig, distance)
	local seat = model:FindFirstChild("DriverSeat")
	local speed = math.abs(rig.chassis.AssemblyLinearVelocity.Magnitude)
	local wanted = distance < ENGINE_DISTANCE and ((seat and seat.Occupant) or speed > 2)
	if not wanted then
		if rig.engineLoop then
			rig.engineLoop:Stop()
			rig.engineLoop = nil
		end
		return
	end
	if not rig.engineLoop then
		local attachment = rig.chassis:FindFirstChild("EngineSound")
		if not attachment then
			attachment = Instance.new("Attachment")
			attachment.Name = "EngineSound"
			attachment.Parent = rig.chassis
		end
		rig.engineLoop = Sfx.Loop("VehicleEngine", attachment)
		if not rig.engineLoop then
			return
		end
	end
	local share = math.clamp(speed / rig.handling.topSpeed, 0, 1)
	rig.engineLoop:SetPitch(1 + share * (ENGINE_PITCH_AT_TOP - 1))
	rig.engineLoop:SetVolume(ENGINE_IDLE_VOLUME + (1 - ENGINE_IDLE_VOLUME) * share)
end

-- Lamps. The parts are Neon and lit by their colour whatever happens; what changes is how bright.
-- A parked vehicle's lamps are dim, a driven one's head lamps come up, and the brake lamps come on
-- when the driver brakes — which every machine can see, because a VehicleSeat's throttle and a
-- model's attributes replicate to everyone. The brightness share itself (and what a wrecked vehicle
-- does to smoke) lives in VehicleWreckFx.lua, a ModuleScript, so it can be required and proven from
-- a gallery the way GunFx/ExplosiveFx already are -- this LocalScript can't be.
-- STRONG keys (bug-hunt B3-2, 2026-09-21): a weak `lamps` table let a collected-and-rebuilt entry
-- re-read `base` from `part.Color` in lampsOf below -- but updateLamps is the only writer of that
-- same property, so a rebuild re-primed `base` from an ALREADY-DIMMED colour. Every drop multiplied
-- the darkening again with no floor (0.34 -> 0.1156 -> 0.039 -> ...), permanently, on any car,
-- wreck or no wreck -- the "harmless cache" verdict this table used to carry was wrong. Dropped
-- explicitly in lampsOf, the same AncestryChanged shape `track()` above already uses for `rigs`.
local lamps = {}

local function lampsOf(model)
	local found = lamps[model]
	if found then
		return found
	end
	found = {}
	-- GetDescendants, not GetChildren (bug-hunt B3-3b): a lamp part nested under a sub-model would
	-- have read as zero found under GetChildren, silently never lighting or dimming.
	for _, part in ipairs(model:GetDescendants()) do
		local role = part:IsA("BasePart") and part:GetAttribute("Lamp")
		if role then
			table.insert(found, { part = part, role = role, base = VehicleWreckFx.LampBaseColor(part) })
		end
	end
	lamps[model] = found
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			lamps[model] = nil
		end
	end)
	return found
end

local function updateLamps(model, distance)
	local found = lampsOf(model)
	local seat = model:FindFirstChild("DriverSeat")
	local driven = seat ~= nil and seat.Occupant ~= nil
	local braking = false
	if driven and seat:IsA("VehicleSeat") then
		local forward = seat.CFrame.LookVector:Dot(seat.AssemblyLinearVelocity)
		braking = seat:GetAttribute("Handbrake") == true or (seat.ThrottleFloat < -0.05 and forward > 1)
			or (seat.ThrottleFloat > 0.05 and forward < -1)
	end
	local wrecked = model:GetAttribute("Wrecked") == true
	-- One number describes the whole state, so nothing is written while nothing changes. This is
	-- the ONLY place anything writes lamp Color -- "wrecked" is folded in as a third bit rather
	-- than a second writer, the failure mode the prompt-reenable bug (#53/#57) already caught once.
	if #found > 0 then
		local state = (driven and 1 or 0) + (braking and 2 or 0) + (wrecked and 4 or 0)
		if lamps[model].state ~= state and distance <= ANIMATE_DISTANCE then
			lamps[model].state = state
			for _, entry in ipairs(found) do
				local share = VehicleWreckFx.LampShare(entry.role, wrecked, driven, braking)
				entry.part.Color = Color3.new(entry.base.R * share, entry.base.G * share, entry.base.B * share)
			end
		end
	end
	-- Bug-hunt B3-3b: this used to sit inside the `#found == 0` early return above, so a vehicle
	-- with no lamp parts at all never smoked when wrecked -- two unrelated features shared one
	-- early return that only ever belonged to lamps.
	VehicleWreckFx.SetSmoke(model, wrecked)
end

--------------------------------------------------------------------------------
-- Moving parts and riders
--------------------------------------------------------------------------------

-- Each character's Motor6Ds by name, found once.
local jointsOf = setmetatable({}, { __mode = "k" })

local function jointsFor(character)
	local joints = jointsOf[character]
	if not joints then
		joints = {}
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("Motor6D") then
				joints[descendant.Name] = descendant
			end
		end
		jointsOf[character] = joints
	end
	return joints
end

-- Riders' joints, set after the character's own animation has run this frame (Stepped comes after
-- animation), so the pose holds until the next frame's animation step.
local function poseRiders(model, focusDistance)
	if focusDistance > POSE_DISTANCE then
		return
	end
	local def = VehicleModels.Models[model:GetAttribute("VehicleModel")]
	if not def then
		return
	end
	for _, seat in ipairs(model:GetChildren()) do
		local occupant = (seat:IsA("Seat") or seat:IsA("VehicleSeat")) and seat.Occupant or nil
		local character = occupant and occupant.Parent
		if character then
			local poseName
			if seat:IsA("VehicleSeat") then
				poseName = model:GetAttribute("RiderPose") or (def.kind == "bike" and "BikeRider" or "CarDriver")
			elseif def.kind == "bike" then
				poseName = "BikePillion"
			end
			local pose = poseName and VehicleModels.Poses[poseName]
			if pose then
				local joints = jointsFor(character)
				for jointName, transform in pairs(pose) do
					local joint = joints[jointName]
					if joint and joint.Parent then
						joint.Transform = transform
					end
				end
			end
		end
	end
end

RunService.Stepped:Connect(function(_, dt)
	frameCount += 1
	local focus = camera.CFrame.Position
	for model, rig in pairs(rigs) do
		if rig and rig.chassis.Parent then
			local distance = (rig.chassis.Position - focus).Magnitude
			if distance < ANIMATE_DISTANCE then
				-- Far vehicles animate every third frame; nobody can tell at that range.
				if distance < FULL_RATE_DISTANCE or frameCount % 3 == 0 then
					local stepDt = distance < FULL_RATE_DISTANCE and dt or dt * 3
					if driving and driving.model == model then
						VehicleDynamics.AnimateWheels(rig, stepDt)
					else
						local seat = model:FindFirstChild("DriverSeat")
						local steer = seat and seat:IsA("VehicleSeat") and seat.SteerFloat * rig.handling.steerLow * 0.6 or 0
						VehicleDynamics.AnimateWheels(rig, stepDt, steer)
					end
				end
				poseRiders(model, distance)
				updateEngine(model, rig, distance)
				updateLamps(model, distance)
			end
		end
	end
end)
