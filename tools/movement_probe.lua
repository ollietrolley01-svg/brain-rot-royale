-- Movement probe: what the movement items, the slide, climbing, vaulting and stamina actually do in real
-- physics. Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/movement_probe.lua -OutDir <folder> -TimeoutSeconds 600
--
-- Same approach as tools/jump_probe.lua: switch the gallery copy into Run mode, build lanes far from the
-- lobby and drive a stock R15 rig with the player's own jump settings. A rig here is simulated by the
-- server, but a player's character runs the same humanoid controller on their client, so distances and
-- speeds carry over. Lanes run in parallel; results print as notes.
--
-- BEFORE lanes reproduce the old behaviour (a launch with nothing holding its speed, the flat x1.9 slide)
-- and the humanoid facts the rework leans on (does a shorter Move vector walk slower, does a velocity
-- written every Heartbeat hold). AFTER lanes run the new behaviour: the client's slide curve and air
-- momentum are repeated here from MovementConfig with the same equations as MovementClient (a LocalScript
-- can't be required), while climbs, vaults and stamina use the real server modules (MovementService
-- TryParkour, MatchService's ledger with StaminaTestMode on). Then three views render the poses.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))

local SLIDE = MovementConfig.Slide
local CROUCH = MovementConfig.Crouch
local AIR = MovementConfig.AirMomentum

local ORIGIN = Vector3.new(-4000, 1500, 3000)
local WALK, SPRINT = 18, 18 * 1.45

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(parent, size, cframe, color, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color or Color3.fromRGB(120, 120, 130)
	part.TopSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local template = nil
local function makeTemplate()
	for attempt = 1, 3 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			return model
		end
		note("rig attempt " .. attempt .. " failed: " .. tostring(model))
		task.wait(2)
	end
	return nil
end

-- Runs `step(dt, elapsed)` every Heartbeat until it returns true or `timeout` passes.
local function drive(timeout, step)
	local started = os.clock()
	local finished = false
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if finished then
			return
		end
		local elapsed = os.clock() - started
		local ok, result = pcall(step, dt, elapsed)
		if not ok then
			note("step error: " .. tostring(result))
			finished = true
		elseif result or elapsed > timeout then
			finished = true
		end
	end)
	while not finished do
		task.wait()
	end
	connection:Disconnect()
end

-- MovementClient's air momentum, one frame of it. Returns the carry, or nil once it has ended.
local function carryStep(carry, humanoid, root, dt)
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded and os.clock() - carry.started > 0.12 then
		return nil
	end
	local actual = flat(root.AssemblyLinearVelocity)
	if os.clock() - carry.started > 0.1 and actual.Magnitude < carry.velocity.Magnitude * 0.35 then
		carry.slowFrames += 1
		if carry.slowFrames >= 3 then
			return nil
		end
	else
		carry.slowFrames = 0
	end
	local m = carry.velocity
	local input = flat(humanoid.MoveDirection)
	if input.Magnitude > 0.1 and m.Magnitude > 0 then
		input = input.Unit
		local heading, speed = m.Unit, m.Magnitude
		if heading:Dot(input) < -0.2 then
			speed = math.max(speed - AIR.Brake * dt, 0)
		else
			local angle = math.acos(math.clamp(heading:Dot(input), -1, 1))
			if angle > 1e-3 then
				local blended = heading:Lerp(input, math.min(1, math.rad(AIR.TurnRate) * dt / angle))
				if blended.Magnitude > 1e-3 then
					heading = blended.Unit
				end
			end
		end
		m = heading * speed
	end
	m *= math.max(1 - AIR.Drag * dt, 0)
	if m.Magnitude < carry.floor then
		return nil
	end
	carry.velocity = m
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(m.X, velocity.Y, m.Z)
	return carry
end

local function newCarry(velocity, floorSpeed)
	local horizontal = flat(velocity)
	if horizontal.Magnitude <= floorSpeed + AIR.MinExcess then
		return nil
	end
	return { velocity = horizontal, floor = floorSpeed + AIR.MinExcess, started = os.clock(), slowFrames = 0 }
end

-- MovementClient's rocket aim with the camera at `pitchDegrees`, facing +X.
local function aimRocket(velocity, pitchDegrees)
	local speed = velocity.Magnitude
	local horizontal = flat(velocity)
	local baseAngle = math.deg(math.atan2(velocity.Y, horizontal.Magnitude))
	local angle = math.rad(math.clamp(baseAngle + pitchDegrees * 0.55, 30, 76))
	return Vector3.new(1, 0, 0) * speed * math.cos(angle) + Vector3.new(0, speed * math.sin(angle), 0)
end

local measurement = {
	name = "movement_probe",
	settle = 1,
	hold = 1,
	setup = function(folder, camera)
		-- Compile the movement client scripts from the place first (client scripts never run here, so this
		-- is the only check they get short of a full runtest).
		local scripts = game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts")
		for _, name in ipairs({ "MovementClient", "MovementState", "StaminaBar", "CombatClient", "HudClient", "Settings" }) do
			local source = scripts and scripts:FindFirstChild(name)
			if not source then
				note("compile " .. name .. ": MISSING")
			else
				local ok, err = loadstring(source.Source)
				note("compile " .. name .. ": " .. (ok and "ok" or ("FAILED " .. tostring(err))))
			end
		end
		if not RunService:IsRunning() then
			RunService:Run()
		end
		task.wait(4)
		note(string.format("gravity %.1f useJumpPower %s jumpPower %.2f jumpHeight %.2f maxSlope %.1f",
			workspace.Gravity, tostring(StarterPlayer.CharacterUseJumpPower), StarterPlayer.CharacterJumpPower,
			StarterPlayer.CharacterJumpHeight, StarterPlayer.CharacterMaxSlopeAngle))

		template = makeTemplate()
		if not template then
			note("no rig, giving up")
			return
		end

		local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
		local Combatants = require(modules:WaitForChild("Combatants"))
		local MovementService = require(modules:WaitForChild("MovementService"))
		local MatchService = require(modules:WaitForChild("MatchService"))
		MovementService.SpendStamina = MatchService.SpendStamina
		MovementService.GetStamina = MatchService.GetStamina

		local laneCount = 0
		local verdicts = {}
		local passedLanes, failedLanes = 0, 0
		local results = {}
		local running = 0

		-- A lane: its own floor (700 long along +X, top at base.Y) and one rig standing at x = 0.
		local function lane(name, body, rigAt)
			laneCount += 1
			local index = laneCount
			running += 1
			task.spawn(function()
				local laneFolder = Instance.new("Folder")
				laneFolder.Name = name
				laneFolder.Parent = folder
				local base = ORIGIN + Vector3.new(0, 0, index * 40)
				block(laneFolder, Vector3.new(700, 4, 24), CFrame.new(base + Vector3.new(250, -2, 0)))
				local rig = template:Clone()
				local humanoid = rig:FindFirstChildOfClass("Humanoid")
				humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
				humanoid.JumpPower = StarterPlayer.CharacterJumpPower
				humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
				humanoid.MaxSlopeAngle = StarterPlayer.CharacterMaxSlopeAngle
				humanoid.WalkSpeed = WALK
				local L = { folder = laneFolder, base = base, rig = rig, humanoid = humanoid, root = rig.HumanoidRootPart }
				local start = rigAt and rigAt(L) or (base + Vector3.new(0, 3.2, 0))
				rig:PivotTo(CFrame.lookAt(start, start + Vector3.new(10, 0, 0)))
				rig.Parent = laneFolder
				task.wait(1.2)
				local ok, result, verdict = pcall(body, L)
				-- A lane that KNOWS what it expects returns a second value; it is marked and tallied here
				-- rather than printed as prose for someone to compare by eye. That is how "2.5x walk for 4s
				-- -> 0 violations (want > 0)" sat in the output failing for weeks.
				local mark = "    "
				if ok and verdict ~= nil then
					mark = verdict and "PASS" or "FAIL"
					verdicts[index] = verdict
				end
				results[index] = string.format("%s %-34s %s", mark, name,
					ok and tostring(result) or ("FAILED " .. tostring(result)))
				laneFolder:Destroy()
				running -= 1
			end)
		end

		----------------------------------------------------------------------------
		-- BEFORE
		----------------------------------------------------------------------------

		lane("rig metrics", function(L)
			local root = L.root
			local rootY = root.Position.Y
			local parts = {}
			for _, name in ipairs({ "Head", "UpperTorso", "LeftHand", "RightHand", "LeftFoot", "RightFoot" }) do
				local part = L.rig:FindFirstChild(name)
				if part then
					table.insert(parts, string.format("%s %+.2f", name, part.Position.Y - rootY))
				end
			end
			local head = L.rig:FindFirstChild("Head")
			return string.format("hip %.2f rootSize %s rootAboveFloor %.2f headTop %+.2f | %s | floor %s",
				L.humanoid.HipHeight, tostring(root.Size), rootY - L.base.Y,
				head and (head.Position.Y + head.Size.Y / 2 - rootY) or 0, table.concat(parts, " "), L.humanoid.FloorMaterial.Name)
		end)

		for _, magnitude in ipairs({ 1, 0.5, 0.25 }) do
			lane(string.format("B move magnitude %.2f", magnitude), function(L)
				L.humanoid.WalkSpeed = 40
				local startX
				drive(2.2, function(_, elapsed)
					L.humanoid:Move(Vector3.new(magnitude, 0, 0), false)
					if elapsed > 1.2 and not startX then
						startX = L.root.Position.X
					end
					return elapsed > 2.2
				end)
				return string.format("WalkSpeed 40 -> measured %.1f studs/s", L.root.Position.X - startX)
			end)
		end

		-- A launch as CombatClient applied one: jumping state, then the velocity, nothing after.
		local function launchLane(label, velocity, input, walkSpeed, withCarry)
			lane(label, function(L)
				L.humanoid.WalkSpeed = walkSpeed
				local start = L.root.Position
				L.humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				L.root.AssemblyLinearVelocity = velocity
				local carry = withCarry and newCarry(velocity, walkSpeed) or nil
				local peak, landedAt, landX = 0, nil, nil
				drive(12, function(dt, elapsed)
					L.humanoid:Move(Vector3.new(input, 0, 0), false)
					if carry then
						carry = carryStep(carry, L.humanoid, L.root, dt)
					end
					peak = math.max(peak, L.root.Position.Y - start.Y)
					if elapsed > 0.3 and L.humanoid.FloorMaterial ~= Enum.Material.Air then
						landedAt, landX = elapsed, L.root.Position.X - start.X
						return true
					end
				end)
				return string.format("peak %.1f, landed %.1f studs out after %.2fs", peak, landX or -1, landedAt or -1)
			end)
		end
		local ROCKET = Vector3.new(72, 88, 0)
		local PAD = Vector3.new(38, 135, 0)
		launchLane("B rocket, no input", ROCKET, 0, WALK, false)
		launchLane("B rocket, hold fwd sprint", ROCKET, 1, SPRINT, false)
		launchLane("B pad, no input", PAD, 0, WALK, false)
		launchLane("B pad, hold fwd sprint", PAD, 1, SPRINT, false)

		for _, slide in ipairs({ false, true }) do
			lane(slide and "B slide (old flat x1.9 0.65s)" or "B sprint only", function(L)
				L.humanoid.WalkSpeed = SPRINT
				local startX
				drive(3.2, function(_, elapsed)
					L.humanoid:Move(Vector3.new(1, 0, 0), false)
					if elapsed > 1.6 and not startX then
						startX = L.root.Position.X
						if slide then
							L.humanoid.WalkSpeed = SPRINT * 1.9
						end
					end
					if slide and elapsed > 2.25 then
						L.humanoid.WalkSpeed = SPRINT
					end
					return elapsed > 3.2
				end)
				return string.format("distance over 1.6s: %.1f", L.root.Position.X - startX)
			end)
		end

		-- Jumps: plain (the Cloud Climb's numbers must not move) and Bounce Boots, with the double jump.
		local function jumpLane(label, boots, doubleJump)
			lane(label, function(L)
				if boots then
					L.humanoid.JumpHeight *= 2.9
					L.humanoid.JumpPower *= math.sqrt(2.9)
				end
				L.humanoid.WalkSpeed = SPRINT
				local start
				local peak, takeoffX, landX, airborne, doubled = 0, nil, nil, false, false
				drive(8, function(_, elapsed)
					L.humanoid:Move(Vector3.new(1, 0, 0), false)
					if elapsed > 1.2 and not takeoffX then
						start = L.root.Position
						takeoffX = start.X
						L.humanoid.Jump = true
					end
					if takeoffX then
						peak = math.max(peak, L.root.Position.Y - start.Y)
						local velocity = L.root.AssemblyLinearVelocity
						if doubleJump and airborne and not doubled and velocity.Y <= 0 then
							doubled = true
							local jumpSpeed = L.humanoid.UseJumpPower and L.humanoid.JumpPower
								or math.sqrt(2 * workspace.Gravity * L.humanoid.JumpHeight)
							L.root.AssemblyLinearVelocity = Vector3.new(velocity.X, jumpSpeed * 0.6, velocity.Z)
						end
						if L.humanoid.FloorMaterial == Enum.Material.Air then
							airborne = true
						elseif airborne then
							landX = L.root.Position.X
							return true
						end
					end
				end)
				return string.format("peak %.2f, sprint flat distance %.1f", peak, (landX or 0) - (takeoffX or 0))
			end)
		end
		jumpLane("jump, plain sprint", false, false)
		jumpLane("A jump, bounce boots", true, false)
		jumpLane("A jump, boots + double jump", true, true)

		local function glideLane(label, height, lift, stored, holdSpeed)
			lane(label, function(L)
				local root, humanoid = L.root, L.humanoid
				if height > 0 then
					L.rig:PivotTo(CFrame.lookAt(L.base + Vector3.new(0, height + 3.2, 0), L.base + Vector3.new(10, height + 3.2, 0)))
				end
				if holdSpeed then
					humanoid.WalkSpeed = holdSpeed
				end
				local start = root.Position
				if lift then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
					root.AssemblyLinearVelocity = Vector3.new(0, lift, 0)
				end
				local airborne, landedAt, peak = false, nil, 0
				local glideVelocity = nil
				drive(20, function(dt, elapsed)
					if holdSpeed then
						humanoid:Move(Vector3.new(1, 0, 0), false)
					end
					peak = math.max(peak, root.Position.Y - start.Y)
					local inAir = humanoid.FloorMaterial == Enum.Material.Air
					if inAir then
						airborne = true
					elseif airborne then
						landedAt = elapsed
						return true
					end
					local velocity = root.AssemblyLinearVelocity
					if airborne then
						-- B: the old blend from the body's (already braked) velocity. A: MovementClient's stored
						-- wing velocity, written in full every frame.
						local base = stored and (glideVelocity or flat(velocity)) or flat(velocity)
						local blended = base:Lerp(Vector3.new(34, 0, 0), math.clamp(dt * (stored and 2.5 or 3), 0, 1))
						if stored then
							glideVelocity = blended
						end
						root.AssemblyLinearVelocity = Vector3.new(blended.X, velocity.Y < -8 and -8 or velocity.Y, blended.Z)
					end
					if elapsed > 16 then
						return true
					end
				end)
				return string.format("peak %+.1f, sailed %.1f in %.1fs", peak, root.Position.X - start.X, landedAt or 16)
			end)
		end
		glideLane("B glider opened on the ground", 0, nil, false)
		glideLane("B glider opened 80 up", 80, nil, false)
		glideLane("A glider opened 80 up", 80, nil, true)
		-- With forward held, as a player gliding would: the humanoid's own air control pushed toward walk
		-- or sprint speed, which propped the old glider up; the fair before/after for balance.
		glideLane("B glider 80 up, holding W at walk", 80, nil, false, WALK)
		glideLane("B glider 80 up, holding W at sprint", 80, nil, false, SPRINT)
		glideLane("A glider 80 up, holding W at sprint", 80, nil, true, SPRINT)
		launchLane("B pad, hold fwd walk", PAD, 1, WALK, false)

		-- Speed Soda on the ground: sprint x1.65 for 10 and 12 seconds, against plain sprinting.
		for _, spec in ipairs({ { "sprint 10s", SPRINT, 10 }, { "soda 10s", SPRINT * 1.65, 10 }, { "soda 12s", SPRINT * 1.65, 12 } }) do
			lane("A " .. spec[1], function(L)
				L.humanoid.WalkSpeed = spec[2]
				local startX
				drive(spec[3] + 1.5, function(_, elapsed)
					L.humanoid:Move(Vector3.new(1, 0, 0), false)
					if elapsed > 1.5 and not startX then
						startX = L.root.Position.X
					end
					return elapsed > spec[3] + 1.5
				end)
				return string.format("covered %.1f studs in %ds", L.root.Position.X - startX, spec[3])
			end)
		end
		launchLane("B rocket, hold fwd walk", ROCKET, 1, WALK, false)
		glideLane("A glider on the ground + updraft", 0, 120, true)

		-- An explosion's knockback (kind "blast"), point blank: 46 sideways and 22 up, entered as Jumping
		-- (the humanoid raises it to a full jump) versus Freefall (what MovementClient does below jump speed).
		for _, state in ipairs({ "Jumping", "Freefall" }) do
			lane("A blast knockback via " .. state, function(L)
				local root, humanoid = L.root, L.humanoid
				local start = root.Position
				local velocity = Vector3.new(46, 22, 0)
				humanoid:ChangeState(Enum.HumanoidStateType[state])
				root.AssemblyLinearVelocity = velocity
				local carry = newCarry(velocity, WALK)
				local peak, landX = 0, nil
				drive(4, function(dt, elapsed)
					if carry then
						carry = carryStep(carry, humanoid, root, dt)
					end
					peak = math.max(peak, root.Position.Y - start.Y)
					if elapsed > 0.15 and humanoid.FloorMaterial ~= Enum.Material.Air then
						landX = root.Position.X - start.X
						return true
					end
				end)
				return string.format("peak %.1f, thrown %.1f studs", peak, landX or -1)
			end)
		end

		for _, withInput in ipairs({ false, true }) do
			lane(withInput and "B velocity write + input" or "B velocity write, no input", function(L)
				L.humanoid.WalkSpeed = SPRINT
				local startX
				drive(2.2, function(_, elapsed)
					L.humanoid:Move(Vector3.new(withInput and 1 or 0, 0, 0), false)
					local v = L.root.AssemblyLinearVelocity
					L.root.AssemblyLinearVelocity = Vector3.new(40, v.Y, v.Z)
					if elapsed > 1.2 and not startX then
						startX = L.root.Position.X
					end
					return elapsed > 2.2
				end)
				return string.format("wrote 40 -> measured %.1f studs/s, state %s", L.root.Position.X - startX, L.humanoid:GetState().Name)
			end)
		end

		----------------------------------------------------------------------------
		-- AFTER
		----------------------------------------------------------------------------

		launchLane("A rocket, no input, level", aimRocket(ROCKET, 0), 0, WALK, true)
		launchLane("A rocket, hold fwd sprint, level", aimRocket(ROCKET, 0), 1, SPRINT, true)
		launchLane("A rocket, no input, look up 40", aimRocket(ROCKET, 40), 0, WALK, true)
		launchLane("A rocket, no input, look down 25", aimRocket(ROCKET, -25), 0, WALK, true)
		launchLane("A pad, no input", PAD, 0, WALK, true)

		lane("A blink mid-air, 40 up", function(L)
			local root, humanoid = L.root, L.humanoid
			L.rig:PivotTo(CFrame.lookAt(L.base + Vector3.new(0, 43.2, 0), L.base + Vector3.new(10, 43.2, 0)))
			task.wait(0.4)
			local start = root.Position
			root.AssemblyLinearVelocity = Vector3.new(30, 0, 0)
			local carry = newCarry(Vector3.new(30, 0, 0), WALK)
			local landedAt
			drive(8, function(dt, elapsed)
				if carry then
					carry = carryStep(carry, humanoid, root, dt)
				end
				if elapsed > 0.3 and humanoid.FloorMaterial ~= Enum.Material.Air then
					landedAt = elapsed
					return true
				end
			end)
			return string.format("carried %.1f studs forward while falling %.1f (%.2fs); without the carry the humanoid brakes it",
				root.Position.X - start.X, start.Y - root.Position.Y, landedAt or -1)
		end)

		-- The client's slide on flat ground, down and up a 12-degree slope, and a slide-jump.
		local function slideLane(label, slopeDegrees, jumpAt)
			local theta = math.rad(slopeDegrees)
			lane(label, function(L)
				local humanoid, root = L.humanoid, L.root
				humanoid.WalkSpeed = SPRINT
				local runStartedAt = os.clock()
				drive(1.4, function()
					humanoid:Move(Vector3.new(1, 0, 0), false)
				end)
				local entry = flat(root.AssemblyLinearVelocity).Magnitude
				local ceiling = SPRINT * SLIDE.PeakMultiplier
				humanoid.WalkSpeed = ceiling
				local dir = Vector3.new(1, 0, 0)
				local speed = math.max(entry, SPRINT) * SLIDE.StartMultiplier
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { L.rig }
				local startX, startY = root.Position.X, root.Position.Y
				local peak, endSpeed, duration = 0, 0, 0
				local jumped, carry = false, nil
				local airSince = nil
				local airFrames, frames, states = 0, 0, {}
				drive(3, function(dt, elapsed)
					local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
					frames += 1
					if not grounded then
						airFrames += 1
					end
					states[humanoid:GetState().Name] = true
					if grounded then
						airSince = nil
					elseif not airSince then
						airSince = os.clock()
					end
					local ground = grounded and workspace:Raycast(root.Position, Vector3.new(0, -5, 0), params)
					if ground then
						speed += SLIDE.SlopeGain * workspace.Gravity * flat(ground.Normal):Dot(dir) * dt
					end
					speed = SLIDE.FloorSpeed + (speed - SLIDE.FloorSpeed) * math.exp(-SLIDE.Friction * dt)
					local actual = flat(root.AssemblyLinearVelocity).Magnitude
					peak = math.max(peak, actual)
					if jumpAt and elapsed >= jumpAt then
						jumped = true
					end
					if jumped or speed < SLIDE.EndSpeed or elapsed > SLIDE.MaxTime or (airSince and os.clock() - airSince > SLIDE.AirGrace) then
						endSpeed, duration = actual, elapsed
						return true
					end
					humanoid:Move(dir * math.clamp(speed / ceiling, 0, 1), false)
				end)
				humanoid.WalkSpeed = SPRINT
				local slideDistance = root.Position.X - startX
				local extra = ""
				if jumped then
					humanoid.Jump = true
					carry = newCarry(root.AssemblyLinearVelocity, SPRINT)
					local takeoffX = root.Position.X
					local airborne = false
					drive(4, function(dt)
						humanoid:Move(Vector3.new(1, 0, 0), false)
						if carry then
							carry = carryStep(carry, humanoid, root, dt)
						end
						if humanoid.FloorMaterial == Enum.Material.Air then
							airborne = true
						elseif airborne then
							return true
						end
					end)
					extra = string.format(", then the jump carried %.1f (plain sprint jump reach is 15.6)", root.Position.X - takeoffX)
				end
				local _ = runStartedAt
				local seen = {}
				for name in pairs(states) do
					table.insert(seen, name)
				end
				return string.format("entry %.1f, peak %.1f, end %.1f after %.2fs: slid %.1f (sprinting covers %.1f in that time), dropped %.1f%s [air %d/%d frames, states %s]",
					entry, peak, endSpeed, duration, slideDistance, SPRINT * duration, startY - root.Position.Y, extra,
					airFrames, frames, table.concat(seen, ","))
			end, slopeDegrees ~= 0 and function(L)
				-- The ramp goes in before the rig is placed on it: descends along +X for a positive slope.
				local normal = Vector3.new(math.sin(theta), math.cos(theta), 0)
				local top = L.base + Vector3.new(60, 60 - math.tan(theta) * 60, 0)
				block(L.folder, Vector3.new(240, 2, 24), CFrame.new(top - normal) * CFrame.Angles(0, 0, -theta))
				return L.base + Vector3.new(-30, 60 + math.tan(theta) * 30 + 3.4, 0)
			end or nil)
		end
		slideLane("A slide, flat", 0, nil)
		slideLane("A slide, 12 deg downhill", 12, nil)
		slideLane("A slide, 12 deg uphill", -12, nil)
		slideLane("A slide-jump at 0.25s, flat", 0, 0.25)

		-- Climbs and vaults run by MovementService.TryParkour (the bots' path) on real geometry.
		local function parkourLane(label, build, approach)
			lane(label, function(L)
				local token = { isBot = true, name = "ProbeRig", character = L.rig }
				Combatants.Register(L.rig, token)
				local wall = build(L)
				local root, humanoid = L.root, L.humanoid
				local kind = nil
				local startedAt = nil
				drive(approach.timeout or 6, function(_, elapsed)
					if not kind then
						if approach.run then
							humanoid.WalkSpeed = approach.run
							humanoid:Move(Vector3.new(1, 0, 0), false)
						end
						if approach.jumpAt and elapsed >= approach.jumpAt and not approach.jumped then
							approach.jumped = true
							humanoid.Jump = true
						end
						local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
						local ready = (not approach.minFeet or feet - L.base.Y >= approach.minFeet)
							and (not approach.within or wall.Position.X - wall.Size.X / 2 - root.Position.X <= approach.within)
						if ready and elapsed > 0.2 then
							kind = MovementService.TryParkour(L.rig, Vector3.new(1, 0, 0), {
								speed = flat(root.AssemblyLinearVelocity).X, groundY = L.base.Y,
							})
							if kind then
								startedAt = elapsed
							end
						end
						return false
					end
					return elapsed - startedAt > 1.4
				end)
				local tilt = math.deg(math.acos(math.clamp(root.CFrame.UpVector.Y, -1, 1)))
				local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2 - L.base.Y
				local result = string.format("kind %s; ends feet %.2f above the ground, x %.1f (obstacle face at %.1f), tilt %.1f, state %s, speed %.1f",
					tostring(kind), feet, root.Position.X - L.base.X, wall.Position.X - wall.Size.X / 2 - L.base.X, tilt,
					humanoid:GetState().Name, flat(root.AssemblyLinearVelocity).Magnitude)
				Combatants.Unregister(L.rig)
				return result
			end)
		end
		parkourLane("A TryParkour mantle wall 6, standing", function(L)
			return block(L.folder, Vector3.new(8, 6, 20), CFrame.new(L.base + Vector3.new(6.2, 3, 0)), Color3.fromRGB(90, 170, 90))
		end, {})
		parkourLane("A TryParkour mantle wall 9, jumping", function(L)
			return block(L.folder, Vector3.new(8, 9, 20), CFrame.new(L.base + Vector3.new(6.2, 4.5, 0)), Color3.fromRGB(90, 170, 90))
		end, { jumpAt = 0.3, minFeet = 2.2 })
		parkourLane("A TryParkour vault fence 3.5 at sprint", function(L)
			return block(L.folder, Vector3.new(0.4, 3.5, 20), CFrame.new(L.base + Vector3.new(24.2, 1.75, 0)), Color3.fromRGB(170, 120, 60))
		end, { run = SPRINT, within = 1.6 })
		parkourLane("A TryParkour vault low wall 2x2.8", function(L)
			return block(L.folder, Vector3.new(2.8, 2, 20), CFrame.new(L.base + Vector3.new(25.4, 1, 0)), Color3.fromRGB(170, 120, 60))
		end, { run = SPRINT, within = 1.6 })
		local function windowBuild(withPane)
			return function(L)
				local x, thick = L.base.X + 24, 1.4
				local cx = x + thick / 2
				local y = L.base.Y
				block(L.folder, Vector3.new(thick, 4, 30), CFrame.new(cx, y + 2, L.base.Z))
				block(L.folder, Vector3.new(thick, 6, 30), CFrame.new(cx, y + 12, L.base.Z))
				block(L.folder, Vector3.new(thick, 5, 12.5), CFrame.new(cx, y + 6.5, L.base.Z - 8.75))
				block(L.folder, Vector3.new(thick, 5, 12.5), CFrame.new(cx, y + 6.5, L.base.Z + 8.75))
				block(L.folder, Vector3.new(20, 1, 30), CFrame.new(cx + thick / 2 + 10, y + 15.5, L.base.Z))
				if withPane then
					block(L.folder, Vector3.new(0.2, 5.2, 5.2), CFrame.new(cx, y + 6.5, L.base.Z), Color3.fromRGB(150, 196, 222),
						{ Name = "WindowGlass", Transparency = 0.45 })
				end
				-- Returned for the face position: the wall below the sill.
				return block(L.folder, Vector3.new(thick, 0.2, 5), CFrame.new(cx, y + 3.9, L.base.Z), Color3.fromRGB(200, 200, 200))
			end
		end
		parkourLane("A TryParkour window, pane broken", windowBuild(false), { run = SPRINT, within = 1.6 })
		-- A pane no longer REFUSES a vault (it used to: "blocked over the lip"). It gets broken instead,
		-- which the lane below proves; this one only shows the plan is now made with the glass in place.
		parkourLane("A TryParkour window, pane intact, now vaults", windowBuild(true), { run = SPRINT, within = 1.6 })

		-- #23, Oliver: "make sure you can break windows by vaulting through them."
		--
		-- The whole path, not the detection half: a real pane, a real vault, and the pane gone afterwards
		-- with the body on the far side. Then the SAME run with the break call swapped for a no-op, which
		-- must leave the pane standing — a planted fault, so a lane that stops breaking anything can't go
		-- on passing quietly.
		--
		-- The window is built under workspace.Map because that is the only place CombatService's glass
		-- breaking looks; a pane anywhere else is invisible to it, which is worth knowing when placing
		-- windows on the map.
		lane("A vault takes the window with it", function(L)
			local token = { isBot = true, name = "ProbeGlass", character = L.rig }
			Combatants.Register(L.rig, token)
			local map = workspace:FindFirstChild("Map")
			local ourMap = nil
			if not map then
				ourMap = Instance.new("Model")
				ourMap.Name = "Map"
				ourMap.Parent = workspace
				map = ourMap
			end
			local frame = Instance.new("Model")
			frame.Name = "ProbeWindowWall"
			frame.Parent = map

			local x, thick = L.base.X + 24, 1.4
			local cx = x + thick / 2
			local y = L.base.Y
			local function wall(size, cframe)
				local part = Instance.new("Part")
				part.Anchored = true
				part.Size = size
				part.CFrame = cframe
				part.Parent = frame
				return part
			end
			local function buildPane()
				local pane = wall(Vector3.new(0.2, 5.2, 5.2), CFrame.new(cx, y + 6.5, L.base.Z))
				pane.Name = "WindowGlass"
				pane.Transparency = 0.45
				pane.Color = Color3.fromRGB(150, 196, 222)
				return pane
			end
			local function panesLeft()
				local count = 0
				for _, part in ipairs(frame:GetDescendants()) do
					if part:IsA("BasePart") and part.Name == "WindowGlass" and part.Parent then
						count += 1
					end
				end
				return count
			end

			wall(Vector3.new(thick, 4, 30), CFrame.new(cx, y + 2, L.base.Z))
			wall(Vector3.new(thick, 6, 30), CFrame.new(cx, y + 12, L.base.Z))
			wall(Vector3.new(thick, 5, 12.5), CFrame.new(cx, y + 6.5, L.base.Z - 8.75))
			wall(Vector3.new(thick, 5, 12.5), CFrame.new(cx, y + 6.5, L.base.Z + 8.75))
			wall(Vector3.new(20, 1, 30), CFrame.new(cx + thick / 2 + 10, y + 15.5, L.base.Z))
			local sill = wall(Vector3.new(thick, 0.2, 5), CFrame.new(cx, y + 3.9, L.base.Z))
			local faceX = sill.Position.X - sill.Size.X / 2

			-- One run at the window, from a standing start, vaulting when close enough.
			local function runAtIt()
				L.rig:PivotTo(CFrame.lookAt(L.base + Vector3.new(0, 3.2, 0), L.base + Vector3.new(10, 3.2, 0)))
				task.wait(0.3)
				local kind, startedAt = nil, nil
				drive(6, function(_, elapsed)
					if not kind then
						L.humanoid.WalkSpeed = SPRINT
						L.humanoid:Move(Vector3.new(1, 0, 0), false)
						if faceX - L.root.Position.X <= 1.6 and elapsed > 0.2 then
							kind = MovementService.TryParkour(L.rig, Vector3.new(1, 0, 0), {
								speed = flat(L.root.AssemblyLinearVelocity).X, groundY = L.base.Y,
							})
							if kind then
								startedAt = elapsed
							end
						end
						return false
					end
					return elapsed - startedAt > 1.4
				end)
				return kind, L.root.Position.X - faceX
			end

			buildPane()
			local before = panesLeft()
			local kind, past = runAtIt()
			local after = panesLeft()

			-- The planted fault: the same vault with nothing breaking the glass.
			local real = MovementService.BreakGlassAlong
			MovementService.BreakGlassAlong = function() end
			buildPane()
			local plantedBefore = panesLeft()
			task.wait(MovementConfig.Parkour.Recovery + 0.3)
			local plantedKind = runAtIt()
			local plantedAfter = panesLeft()
			MovementService.BreakGlassAlong = real

			frame:Destroy()
			if ourMap then
				ourMap:Destroy()
			end
			Combatants.Unregister(L.rig)

			local broke = kind == "vault" and before == 1 and after == 0 and past > 0.5
			local plantedHeld = plantedKind == "vault" and plantedBefore == 1 and plantedAfter == 1
			return string.format("vault %s: panes %d -> %d, ended %.1f studs past the window face | "
				.. "planted (break removed) %s: panes %d -> %d (want 1 -> 1)",
				tostring(kind), before, after, past, tostring(plantedKind), plantedBefore, plantedAfter),
				broke and plantedHeld
		end)

		-- The server's grounded gate for a slide. It used to read Humanoid.FloorMaterial, which is not the
		-- server's to trust for a body it doesn't simulate; it now casts a ray past the feet. The closest
		-- stand-in for a client-simulated body available here is an ANCHORED rig (nobody simulates it), so
		-- this shows the gate decides from the world, not from the humanoid's own state. A live match is
		-- still the only place to see a real player's slide end to end (playtest checklist).
		lane("A slide gate: air / floor / NoMantle", function(L)
			local token = { isBot = true, name = "ProbeGate", character = L.rig }
			Combatants.Register(L.rig, token)
			local root = L.root
			root.Anchored = true
			MatchService.SetSprinting(token, true)

			L.rig:PivotTo(CFrame.new(L.base + Vector3.new(0, 30, 0)))
			task.wait(0.2)
			local inAir = MatchService.StartSlide(token)
			local airFloor = L.humanoid.FloorMaterial.Name

			L.rig:PivotTo(CFrame.new(L.base + Vector3.new(0, 3.2, 0)))
			task.wait(0.2)
			local onFloor = MatchService.StartSlide(token)
			MatchService.EndSlide(token)
			task.wait(SLIDE.Cooldown + 0.2)

			local pad = block(L.folder, Vector3.new(14, 2, 14), CFrame.new(L.base + Vector3.new(40, 1, 0)),
				Color3.fromRGB(150, 120, 200))
			pad:SetAttribute("NoMantle", true)
			L.rig:PivotTo(CFrame.new(L.base + Vector3.new(40, 2 + 3.2, 0)))
			task.wait(0.2)
			local onNoMantle = MatchService.StartSlide(token)

			MatchService.SetSprinting(token, false)
			root.Anchored = false
			Combatants.Unregister(L.rig)
			return string.format("held 30 up: %s (want false, humanoid said floor=%s), on the floor: %s (want true), on NoMantle ground: %s (want false)",
				tostring(inAir), airFloor, tostring(onFloor), tostring(onNoMantle)),
				inAir == false and onFloor == true and onNoMantle == false
		end)

		-- A slide lowers the body exactly as a crouch does — it didn't used to, which made "slide under a
		-- gap" impossible and left the slide as nothing but a speed burst. Both states go through
		-- MatchService's one height rule, so this walks the whole interaction including the case that rule
		-- exists for: a slide ENDING while a crouch is held must leave the body down, not stand it up.
		lane("A slide and a crouch both lower the body", function(L)
			local token = { isBot = true, name = "ProbeLow", character = L.rig }
			Combatants.Register(L.rig, token)
			local humanoid, root = L.humanoid, L.root
			root.Anchored = true
			L.rig:PivotTo(CFrame.new(L.base + Vector3.new(0, 3.2, 0)))
			task.wait(0.2)
			local standing = humanoid.HipHeight

			MatchService.SetCrouching(token, true)
			local crouched = humanoid.HipHeight
			MatchService.SetCrouching(token, false)
			local afterCrouch = humanoid.HipHeight

			MatchService.SetSprinting(token, true)
			local slid = MatchService.StartSlide(token)
			local sliding = humanoid.HipHeight
			MatchService.EndSlide(token)
			local afterSlide = humanoid.HipHeight

			-- Now the one that matters: crouch DURING a slide, then end the slide. Crouching clears the
			-- sprint, so this is also the path a client takes when its slide runs out with the key held.
			task.wait(SLIDE.Cooldown + 0.2)
			MatchService.SetSprinting(token, true)
			local slidAgain = MatchService.StartSlide(token)
			MatchService.SetCrouching(token, true)
			MatchService.EndSlide(token)
			local heldDown = humanoid.HipHeight
			MatchService.SetCrouching(token, false)
			local finally = humanoid.HipHeight

			MatchService.SetSprinting(token, false)
			root.Anchored = false
			Combatants.Unregister(L.rig)
			local ok = crouched < standing - 0.2 and math.abs(afterCrouch - standing) < 0.01
				and slid and sliding < standing - 0.2 and math.abs(afterSlide - standing) < 0.01
				and slidAgain and heldDown < standing - 0.2 and math.abs(finally - standing) < 0.01
			return string.format("standing %.2f | crouched %.2f, back up %.2f | sliding %.2f (started %s), "
				.. "back up %.2f | slide ended into a held crouch %.2f, then stood %.2f",
				standing, crouched, afterCrouch, sliding, tostring(slid), afterSlide, heldDown, finally), ok
		end)

		-- The movement sanity monitor, both ways. Legit play must count ZERO (and prints the worst excess
		-- seen, which is the margin left); planted faults must be counted, or the monitor is worthless.
		local MovementSanity = require(modules:WaitForChild("MovementSanity"))
		lane("A sanity monitor: legit play", function(L)
			local key, rig, humanoid, root = "ProbeLegit", L.rig, L.humanoid, L.root
			MovementSanity.Reset(key)
			MovementSanity.Watch(key, rig)
			task.wait(MovementSanity.Tuning.Grace + 0.2)

			-- Sprinting, then a slide at the server's ceiling.
			humanoid.WalkSpeed = SPRINT
			drive(2.5, function()
				humanoid:Move(Vector3.new(1, 0, 0), false)
			end)
			humanoid.WalkSpeed = SPRINT * SLIDE.PeakMultiplier
			drive(1.1, function()
				humanoid:Move(Vector3.new(1, 0, 0), false)
			end)
			humanoid.WalkSpeed = SPRINT

			-- A Rot Rocket: granted, then flown with the client's momentum carry.
			MovementSanity.Grant(key, 72, 1.5)
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			root.AssemblyLinearVelocity = Vector3.new(72, 88, 0)
			local carry = newCarry(Vector3.new(72, 88, 0), SPRINT)
			drive(2.5, function(dt, elapsed)
				if carry then
					carry = carryStep(carry, humanoid, root, dt)
				end
				return elapsed > 0.4 and humanoid.FloorMaterial ~= Enum.Material.Air
			end)

			-- A glider: granted, with a canopy over the head, sailing at 34.
			local canopy = Instance.new("Model")
			canopy.Name = "GliderCanopy"
			canopy.Parent = rig
			MovementSanity.Grant(key, 34, 4)
			root.AssemblyLinearVelocity = Vector3.new(34, 0, 0)
			drive(2, function()
				local velocity = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(34, math.max(velocity.Y, -8), velocity.Z)
			end)
			canopy:Destroy()
			task.wait(0.3)

			-- A Blink Bean: the server teleports the body itself, so it says so first.
			MovementSanity.Expect(key)
			rig:PivotTo(rig:GetPivot() + Vector3.new(44, 0, 0))
			task.wait(0.6)

			-- A vehicle seat, moving faster than anyone can run.
			local seat = Instance.new("VehicleSeat")
			seat.Size = Vector3.new(6, 1, 6)
			seat.Anchored = true
			seat.CFrame = CFrame.new(root.Position - Vector3.new(0, 2.6, 0))
			seat.Parent = L.folder
			local sat = pcall(function()
				seat:Sit(humanoid)
			end)
			if sat then
				task.wait(0.4)
				drive(2, function(dt)
					seat.CFrame = seat.CFrame + Vector3.new(80 * dt, 0, 0)
				end)
				humanoid.Sit = false
			end
			task.wait(0.3)

			local report = MovementSanity.GetReport()
			local body = report.bodies[key] or {}
			MovementSanity.Unwatch(key)
			-- The number that sets the drain rate: how fast honest play piles excess into the bucket. The
			-- drain has to clear this comfortably, and every stud per second of drain above it is free
			-- speed a cheat can sit inside forever.
			local seconds = (body.samples or 0) / MovementSanity.Tuning.Rate
			local piled = (body.totalExcess or 0) / math.max(seconds, 0.01)
			return string.format("violations %d (want 0) over %d samples; worst excess %.2f studs in a sample; "
				.. "honest play piles %.2f studs/s of excess (the drain is %.0f); seat test %s",
				body.violations or -1, body.samples or 0, body.worstExcess or 0, piled,
				MovementSanity.Tuning.DrainRate, tostring(sat)),
				(body.violations or -1) == 0 and (body.samples or 0) > 0
		end)

		-- Crouching out of a run cuts the expected speed on the instant while the body is still coasting
		-- down to it. Before MovementSanity kept a decaying ceiling, every honest player who did it
		-- collected strikes — and strikes against honest players are what bury the real ones.
		lane("A sanity monitor: crouching out of a run", function(L)
			local key, rig, humanoid = "ProbeCrouch", L.rig, L.humanoid
			MovementSanity.Reset(key)
			MovementSanity.Watch(key, rig)
			task.wait(MovementSanity.Tuning.Grace + 0.2)
			humanoid.WalkSpeed = SPRINT
			drive(2, function()
				humanoid:Move(Vector3.new(1, 0, 0), false)
			end)
			-- Exactly what applySpeed does the moment the crouch lands: no sprint, and the crouch factor.
			humanoid.WalkSpeed = WALK * CROUCH.SpeedMultiplier
			drive(1.5, function()
				humanoid:Move(Vector3.new(1, 0, 0), false)
			end)
			local body = MovementSanity.GetReport().bodies[key] or {}
			MovementSanity.Unwatch(key)
			humanoid.WalkSpeed = WALK
			return string.format("violations %d (want 0) over %d samples; worst excess %.2f studs in a sample",
				body.violations or -1, body.samples or 0, body.worstExcess or 0),
				(body.violations or -1) == 0 and (body.samples or 0) > 0
		end)

		-- How long a plain sustained speed hack can run before the monitor counts it — measured, not
		-- assumed. This used to assert "2.5x for 4 seconds is caught", which quietly passed as a FAILURE
		-- for a long time: the bucket needs 8.5s at that speed, and a 2x hack never fills it at all.
		lane("A sanity monitor: how long a speed hack lasts", function(L)
			local key, rig, humanoid, root = "ProbeSustained", L.rig, L.humanoid, L.root
			local function timeToCatch(multiplier, limit)
				MovementSanity.Reset(key)
				MovementSanity.Watch(key, rig)
				root.Anchored = true
				humanoid.WalkSpeed = WALK
				task.wait(MovementSanity.Tuning.Grace + 0.2)
				local began = os.clock()
				local caught = nil
				drive(limit, function(dt)
					rig:PivotTo(rig:GetPivot() + Vector3.new(WALK * multiplier * dt, 0, 0))
					if not caught and ((MovementSanity.GetReport().bodies[key] or {}).violations or 0) > 0 then
						caught = os.clock() - began
					end
				end)
				MovementSanity.Unwatch(key)
				root.Anchored = false
				return caught
			end
			local parts = {}
			local caughtAt = {}
			for _, multiplier in ipairs({ 1.5, 2, 2.5, 4 }) do
				local caught = timeToCatch(multiplier, 12)
				caughtAt[multiplier] = caught
				table.insert(parts, string.format("%.1fx %s", multiplier,
					caught and string.format("in %.1fs", caught) or "NEVER in 12s"))
			end
			-- 2.5x and 4x MUST be counted. 1.5x and 2x are reported, not asserted: at the tuning as it
			-- stands they are never counted at all, and that is the hole this lane exists to size rather
			-- than to hide. Tighten this once the drain is retuned against the honest-accumulation number
			-- the legit lane now prints.
			local mustCatch = caughtAt[2.5] ~= nil and caughtAt[4] ~= nil
			return "time to count a sustained speed hack: " .. table.concat(parts, ", "), mustCatch
		end)

		lane("A sanity monitor: planted faults", function(L)
			local key, rig, humanoid, root = "ProbePlanted", L.rig, L.humanoid, L.root
			MovementSanity.Reset(key)
			MovementSanity.Watch(key, rig)
			root.Anchored = true
			humanoid.WalkSpeed = WALK
			task.wait(MovementSanity.Tuning.Grace + 0.2)

			-- A sustained 2.5x walk, driven by teleporting the body rather than walking it. Long enough
			-- for the bucket to fill at that speed (see the lane above for what "long enough" is).
			drive(10, function(dt)
				rig:PivotTo(rig:GetPivot() + Vector3.new(WALK * 2.5 * dt, 0, 0))
			end)
			local afterRun = (MovementSanity.GetReport().bodies[key] or {}).violations or 0

			-- 2. Repeated 40-stud jumps with no Expect.
			for _ = 1, 5 do
				rig:PivotTo(rig:GetPivot() + Vector3.new(40, 0, 0))
				task.wait(0.3)
			end
			local report = MovementSanity.GetReport()
			local body = report.bodies[key] or {}
			root.Anchored = false
			MovementSanity.Unwatch(key)
			return string.format("2.5x walk for 10s -> %d violations (want > 0); then five 40-stud jumps -> %d total (want more), worst excess %.1f",
				afterRun, body.violations or -1, body.worstExcess or 0),
				afterRun > 0 and (body.violations or 0) > afterRun
		end)

		-- The stamina ledger itself (MatchService, StaminaTestMode on), on a bot-shaped token.
		lane("A stamina: sprint to empty and back", function(L)
			MatchService.StaminaTestMode = true
			local token = { isBot = true, name = "ProbeRig", character = L.rig }
			Combatants.Register(L.rig, token)
			local humanoid, root = L.humanoid, L.root
			MatchService.SetBaseSpeed(token, 18)
			local base = humanoid.WalkSpeed
			MatchService.SetSprinting(token, true)
			local sprintSpeed = humanoid.WalkSpeed
			local slideOk = MatchService.StartSlide(token)
			local afterSlide = MatchService.GetStamina(token)
			local slideSpeed = humanoid.WalkSpeed
			local secondSlide = MatchService.StartSlide(token)
			local ended = MatchService.EndSlide(token)
			local log = {}
			local exhaustedAt, recoveredAt, walkWhileEx, speedAfter
			drive(22, function(_, elapsed)
				humanoid:Move(Vector3.new(1, 0, 0), false)
				local fraction, exhausted = MatchService.GetStamina(token)
				if exhausted and not exhaustedAt then
					exhaustedAt = elapsed
					task.delay(0.3, function()
						walkWhileEx = humanoid.WalkSpeed
					end)
				end
				if exhaustedAt and not exhausted and not recoveredAt then
					recoveredAt = elapsed
					task.delay(0.3, function()
						speedAfter = humanoid.WalkSpeed
					end)
				end
				if math.floor(elapsed * 2) ~= #log - 1 and #log < 45 then
					table.insert(log, string.format("%.0f", fraction * 100))
				end
				return recoveredAt and elapsed > recoveredAt + 0.5
			end)
			MatchService.SetSprinting(token, false)
			MatchService.StaminaTestMode = false
			Combatants.Unregister(L.rig)
			return string.format("base %.1f sprint %.1f | slide ok %s -> stamina %.0f%%, speed %.1f, second slide %s, EndSlide %s | exhausted at %.1fs (walk %.1f), recovered at %.1fs (speed %.1f) | every 0.5s: %s",
				base, sprintSpeed, tostring(slideOk), afterSlide * 100, slideSpeed, tostring(secondSlide), tostring(ended),
				exhaustedAt or -1, walkWhileEx or -1, recoveredAt or -1, speedAfter or -1, table.concat(log, " "))
		end)

		while running > 0 do
			task.wait(0.5)
		end
		for index = 1, laneCount do
			note(string.format("%02d %s", index, tostring(results[index])))
			if verdicts[index] == true then
				passedLanes += 1
			elseif verdicts[index] == false then
				failedLanes += 1
			end
		end
		note(string.format("lanes with an expectation: %d passed, %d FAILED (the rest are measurements)",
			passedLanes, failedLanes))
		camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-30, 30, -40), ORIGIN)
	end,
}

-- Pose renders: a rig held in each pose, from the side and three-quarters.
local function poseView(kind, angle)
	return {
		name = "pose_" .. kind .. "_" .. angle,
		settle = 1.5,
		setup = function(folder, camera)
			if not template then
				template = makeTemplate()
			end
			if not template then
				return
			end
			local spot = ORIGIN + Vector3.new(0, 200, -200)
			block(folder, Vector3.new(30, 1, 30), CFrame.new(spot + Vector3.new(0, -0.5, 0)), Color3.fromRGB(100, 140, 90))
			local rig = template:Clone()
			local stand = rig:FindFirstChildOfClass("Humanoid").HipHeight + rig.HumanoidRootPart.Size.Y / 2
			rig:PivotTo(CFrame.lookAt(spot + Vector3.new(0, stand, 0), spot + Vector3.new(10, stand, 0)))
			rig.HumanoidRootPart.Anchored = true
			-- A stock rig from a description is a physics rig: its joints are AnimationConstraints with
			-- limited torque, so a raised leg sags under gravity and the render lies. Kinematic joints
			-- hold the Transform exactly, like a player's Motor6Ds.
			for _, joint in ipairs(rig:GetDescendants()) do
				if joint:IsA("AnimationConstraint") then
					pcall(function()
						joint.IsKinematic = true
					end)
				end
			end
			rig.Parent = folder
			local joints = Parkour.PoseJoints(rig)
			if not joints then
				note("pose " .. kind .. ": no R15 joints")
				return
			end
			local connection = RunService.Stepped:Connect(function()
				if rig.Parent then
					Parkour.ApplyPose(joints, kind, 1)
				end
			end)
			rig.Destroying:Connect(function()
				connection:Disconnect()
			end)
			local eye = angle == "side" and Vector3.new(0, 2, -11) or Vector3.new(8, 3.5, -8)
			camera.CFrame = CFrame.lookAt(spot + eye, spot + Vector3.new(0, 1.8, 0))
		end,
	}
end

return {
	measurement,
	poseView("slide", "side"),
	poseView("slide", "quarter"),
	poseView("mantle", "side"),
	poseView("mantle", "quarter"),
	poseView("vault", "side"),
	poseView("vault", "quarter"),
}
