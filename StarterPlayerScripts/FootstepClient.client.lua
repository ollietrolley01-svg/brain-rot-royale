-- Footsteps that sound like the ground they land on (#120).
--
-- Roblox's own character sound script plays one looping "Running" sound for every player's body,
-- the same plastic patter on grass, wood or water, and bots (which it doesn't run for) make no
-- steps at all. This replaces it: each body near the camera, bots included, steps at a cadence
-- set by how fast it is actually moving, and each step is the cue for Humanoid.FloorMaterial
-- (SoundConfig.Footsteps). Other bodies step from their feet, positionally, so you can hear
-- someone coming round a corner; your own steps play flat and quieter.
--
-- The built-in loop is silenced by emptying its SoundId, not by turning its Volume down, because
-- MovementClient already owns that Volume (it lowers it while a body crouches and hands it back
-- afterwards); two writers on one property would undo each other. The crouch hush is applied
-- here instead, with the same MovementConfig.Crouch.StepVolume.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local STEPS = SoundConfig.Footsteps
local CROUCH = MovementConfig.Crouch

local SCAN_EVERY = 1
local TRIM_EVERY = 0.25

-- model -> { humanoid, root, phase, heard, connections }. Strong keys, pruned on every scan: a
-- weak-keyed table would drop a body while it was still walking about.
local bodies = {}

local function silence(sound)
	if sound.SoundId ~= "" then
		sound.SoundId = ""
	end
end

-- The built-in "Running" loop sits on the root part, and the sound script can make it after we
-- first see the body, so it is looked for now and whenever the root gains a child.
local function silenceRunning(entry)
	local function hook(child)
		if child.Name == "Running" and child:IsA("Sound") then
			silence(child)
			table.insert(entry.connections, child:GetPropertyChangedSignal("SoundId"):Connect(function()
				silence(child)
			end))
		end
	end
	for _, child in ipairs(entry.root:GetChildren()) do
		hook(child)
	end
	table.insert(entry.connections, entry.root.ChildAdded:Connect(hook))
end

local function forget(model)
	local entry = bodies[model]
	if entry then
		for _, connection in ipairs(entry.connections) do
			connection:Disconnect()
		end
		bodies[model] = nil
	end
end

local function scan()
	for model in pairs(bodies) do
		local entry = bodies[model]
		if not model.Parent or not entry.root.Parent or not entry.humanoid.Parent then
			forget(model)
		end
	end
	for _, model in ipairs(workspace:GetChildren()) do
		if not bodies[model] and model:IsA("Model") then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			if humanoid and root then
				local entry = { humanoid = humanoid, root = root, phase = 0.5, heard = false, connections = {} }
				bodies[model] = entry
				silenceRunning(entry)
			end
		end
	end
end

-- Only the MAX_BODIES nearest bodies inside REACH step: a crowded fight shouldn't turn into
-- forty sets of feet, and one far enough off to be culled by rolloff shouldn't cost a pool slot.
local function trim()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local near = {}
	for model, entry in pairs(bodies) do
		entry.heard = false
		local distance = (entry.root.Position - eye).Magnitude
		if distance <= STEPS.REACH then
			table.insert(near, { entry = entry, distance = distance })
		end
	end
	table.sort(near, function(a, b)
		return a.distance < b.distance
	end)
	for index = 1, math.min(#near, STEPS.MAX_BODIES) do
		near[index].entry.heard = true
	end
end

local function stepFor(model, entry, dt)
	local humanoid = entry.humanoid
	if humanoid.Health <= 0 then
		return
	end
	local state = humanoid:GetState()
	if state == Enum.HumanoidStateType.Swimming or state == Enum.HumanoidStateType.Climbing then
		return
	end
	local cue = SoundConfig.FootstepCue(humanoid.FloorMaterial.Name)
	if not cue then
		-- In the air: no steps, and the first one after landing comes half a stride in.
		entry.phase = 0.5
		return
	end
	local velocity = entry.root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local rate = SoundConfig.StepRate(speed)
	if rate <= 0 then
		entry.phase = 0.5
		return
	end
	entry.phase += dt * rate
	if entry.phase < 1 then
		return
	end
	entry.phase %= 1

	local gain = SoundConfig.StepGain(speed)
	if model:GetAttribute("Crouching") == true then
		gain *= CROUCH.StepVolume
	end
	if model == Players.LocalPlayer.Character then
		Sfx.Play(cue, 0.1, nil, gain * STEPS.SELF_GAIN)
	else
		local feet = entry.root.Position - Vector3.new(0, humanoid.HipHeight + entry.root.Size.Y / 2, 0)
		Sfx.PlayAt(cue, feet, 0.1, nil, gain)
	end
end

local sinceScan, sinceTrim = SCAN_EVERY, TRIM_EVERY
RunService.Heartbeat:Connect(function(dt)
	sinceScan += dt
	if sinceScan >= SCAN_EVERY then
		sinceScan = 0
		scan()
	end
	sinceTrim += dt
	if sinceTrim >= TRIM_EVERY then
		sinceTrim = 0
		trim()
	end
	for model, entry in pairs(bodies) do
		if entry.heard and model.Parent then
			stepFor(model, entry, dt)
		end
	end
end)
