-- The local player's movement: stamina, the slide, ledge climbing and vaulting, keeping a launch's
-- speed through the air, the Bounce Boots' double jump and the Rot Glider — plus the slide / climb /
-- vault poses on everyone's bodies. Tuning is in Shared/MovementConfig; ledges and paths come from
-- Shared/Parkour; MovementState is the table CombatClient (sprint and slide keys, the gun dip) and
-- HudClient (the stamina bar) read.
--
-- The character is simulated on this client, so moves run here and the server is told:
--   * Stamina is predicted here with the server's own numbers and corrected by StaminaSync. The
--     server's ledger is the real one: it takes the sprint factor off when you're exhausted and
--     refuses slides and vaults you can't pay for, whatever this script thinks.
--   * A slide asks the server (Slide), which puts a speed CEILING on (Slide.PeakMultiplier). This
--     script shapes the real speed under it each frame through the humanoid's move vector — a burst
--     that bleeds off, faster downhill, steerable — and says when it's over (SlideEnd).
--   * A climb or vault is a path from Parkour.Find: the root follows it with its velocity held at zero,
--     then leaves with the plan's exit velocity. The server is told (Parkour) to charge stamina and to
--     pose the body for everyone else.
--   * Launches (Launch) from a Rot Rocket, Launch Pad or Blink Bean keep their horizontal speed until
--     you land, instead of the humanoid's air control braking them to walking pace; you can steer and
--     pull back. A launch with no kind (the geyser) is applied exactly as it always was.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local CrouchAnimation = require(Shared:WaitForChild("CrouchAnimation"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

local MovementState = require(script.Parent:WaitForChild("MovementState"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local STAMINA = MovementConfig.Stamina
local SLIDE = MovementConfig.Slide
local AIR = MovementConfig.AirMomentum
local CROUCH = MovementConfig.Crouch
local PARKOUR = MovementConfig.Parkour

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local slideRemote = Remotes.Event("Slide")
local slideEndRemote = Remotes.Event("SlideEnd")
local parkourRemote = Remotes.Event("Parkour")
local staminaSync = Remotes.Event("StaminaSync")
local crouchRemote = Remotes.Event("SetCrouching")

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

--------------------------------------------------------------------------------
-- Context: the character, and whether a match is on for us
--------------------------------------------------------------------------------

local character, humanoid, root = nil, nil, nil
-- The slide and the climb or vault under way, and the slide's ender. Declared up here because the
-- launch handler, above their own sections, cancels them.
local slide = nil
local active = nil
local endSlide
-- Crouch's setter, declared here because the slide's ending and the climb/vault transitions above its
-- own section use it.
local setCrouching
-- How tall the body is right now. Crouching and sliding BOTH lower it, so one function owns the write
-- and the slide's start and end — which are above the crouch's own section — call it too.
local applyBodyHeight
local matchState = "Waiting"
local hasLoadout = false
local loadout = nil
local rangeActive = false

local function alive()
	return humanoid ~= nil and root ~= nil and humanoid.Health > 0 and root.Parent ~= nil
end

-- Stamina, climbing and vaulting are for matches: in the lobby the bar hides and sprint is free.
local function inMatch()
	return matchState == "InProgress" and hasLoadout and not rangeActive
end

Remotes.Event("MatchChanged").OnClientEvent:Connect(function(state)
	if type(state) == "table" and type(state.state) == "string" then
		matchState = state.state
	end
end)
Remotes.Event("LoadoutChanged").OnClientEvent:Connect(function(newLoadout)
	loadout = type(newLoadout) == "table" and newLoadout or nil
	hasLoadout = loadout ~= nil
end)
Remotes.Event("RangeState").OnClientEvent:Connect(function(on)
	rangeActive = on == true
end)

-- The player module's move vector, for steering a slide (A/D) while this script holds the move.
local controls = nil
task.spawn(function()
	local ok, module = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 20))
	end)
	if ok and module and module.GetControls then
		controls = module:GetControls()
	end
end)

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true
groundParams.IgnoreWater = true

local function groundHit(distance)
	groundParams.FilterDescendantsInstances = { character }
	local reach = humanoid.HipHeight + root.Size.Y / 2 + (distance or 1.5)
	return workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), groundParams)
end

--------------------------------------------------------------------------------
-- Stamina (predicted)
--------------------------------------------------------------------------------

local lastSpend = 0

-- Running out of stamina makes no sound: the bar already says it, in red, pulsing, with a tick at the
-- line where sprinting comes back. A noise on top of that was just nagging.
local function setExhausted(value)
	MovementState._SetExhausted(value)
end

-- Mirrors MatchService.SpendStamina, so the HUD bites at once and a refused move isn't attempted.
local function predictSpend(amount, allowDebt)
	if not inMatch() or MovementState.rush or amount <= 0 then
		return true
	end
	if not allowDebt and (MovementState.exhausted or MovementState.stamina < amount) then
		return false
	end
	MovementState.stamina = math.max(MovementState.stamina - amount, 0)
	lastSpend = os.clock()
	if MovementState.stamina <= 0 then
		setExhausted(true)
	end
	return true
end

staminaSync.OnClientEvent:Connect(function(value, exhausted, rush)
	if not SafeValue.Number(value, 1000) then
		return
	end
	MovementState.rush = rush == true
	-- Small differences are latency (the server sampled a moment ago): ease toward it. Big ones are
	-- a real disagreement: take the server's number.
	local difference = value - MovementState.stamina
	if math.abs(difference) > 6 then
		MovementState.stamina = value
	else
		MovementState.stamina += difference * 0.5
	end
	-- The server's exhaustion always wins (it has already taken the sprint off). Its "not exhausted" only
	-- overrides ours once it has really recovered, or clearly has more than we think: right at zero the
	-- two sides cross a few frames apart, and flipping on every sync would flicker the sprint.
	if exhausted == true then
		setExhausted(true)
	elseif MovementState.exhausted and (value >= STAMINA.ExhaustedUntil or value > MovementState.stamina + 6) then
		setExhausted(false)
	end
end)

local function stepStamina(dt)
	local now = os.clock()
	if not inMatch() or MovementState.rush then
		MovementState.stamina = STAMINA.Max
		MovementState.draining = false
		setExhausted(false)
		return
	end
	local draining = false
	-- Only running on the ground drains, as on the server: not a seat, not a flight through the air.
	if MovementState.sprinting and not MovementState.exhausted and alive() and not humanoid.Sit
		and humanoid.FloorMaterial ~= Enum.Material.Air then
		draining = flat(root.AssemblyLinearVelocity).Magnitude > STAMINA.MovingSpeed
	end
	MovementState.draining = draining
	if draining then
		MovementState.stamina = math.max(MovementState.stamina - STAMINA.SprintDrainPerSecond * dt, 0)
		lastSpend = now
		if MovementState.stamina <= 0 then
			setExhausted(true)
		end
	elseif now - lastSpend >= (MovementState.exhausted and STAMINA.ExhaustedRegenDelay or STAMINA.RegenDelay) then
		MovementState.stamina = math.min(MovementState.stamina + STAMINA.RegenPerSecond * dt, STAMINA.Max)
		if MovementState.exhausted and MovementState.stamina >= STAMINA.ExhaustedUntil then
			setExhausted(false)
		end
	end
end

--------------------------------------------------------------------------------
-- Air momentum
--------------------------------------------------------------------------------

-- { velocity = flat Vector3, floor = speed it ends under, started, slowFrames }
local carry = nil

local function startCarry(velocity, floorSpeed)
	local horizontal = flat(velocity)
	local floor = (floorSpeed or (humanoid and humanoid.WalkSpeed or 18)) + AIR.MinExcess
	if horizontal.Magnitude <= floor then
		carry = nil
		return
	end
	carry = { velocity = horizontal, floor = floor, started = os.clock(), slowFrames = 0 }
end

local function stepCarry(dt, busy)
	if not carry then
		return
	end
	local now = os.clock()
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if busy or not alive() or humanoid.Sit or humanoid:GetState() == Enum.HumanoidStateType.Swimming
		or (grounded and now - carry.started > 0.12) then
		carry = nil
		return
	end
	-- Ran into something: physics has already stopped us, so stop pushing.
	local actual = flat(root.AssemblyLinearVelocity)
	if now - carry.started > 0.1 and actual.Magnitude < carry.velocity.Magnitude * 0.35 then
		carry.slowFrames += 1
		if carry.slowFrames >= 3 then
			carry = nil
			return
		end
	else
		carry.slowFrames = 0
	end

	local m = carry.velocity
	local speed = m.Magnitude
	local input = flat(humanoid.MoveDirection)
	if input.Magnitude > 0.1 and speed > 0 then
		input = input.Unit
		local heading = m.Unit
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
		carry = nil
		return
	end
	carry.velocity = m
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(m.X, velocity.Y, m.Z)
end

--------------------------------------------------------------------------------
-- Glider (the Rot Glider and the match drop-in)
--------------------------------------------------------------------------------

-- While it lasts, falling is capped to a gentle drift; the canopy over your head is added by the
-- server so everyone sees it.
local GLIDE_FALL_SPEED = 8
-- What a canopy sails at if the server's number ever fails its check. Never 0: that lands in the branch
-- that only caps the fall, which is the one nobody had tested.
local GLIDE_FORWARD = 34
local glideUntil = 0
local glideFallSpeed = GLIDE_FALL_SPEED
-- How fast the glider carries you forward, the way the camera looks: it's a glider, not a
-- parachute, so you cover ground with it. Steer by looking.
local glideForward = 0
-- Set once the glide has actually had air under it, so touching down ends it — but a glider
-- popped while still standing on the ground isn't cancelled before it's done anything.
local glideAirborne = false
-- The wing's own horizontal velocity. Written in full every frame: blending from the body's velocity
-- each frame let the humanoid's air control brake it back down (a glider opened 80 up with no key
-- held sailed 4 studs, measured by tools/movement_probe.lua).
local glideVelocity = nil

local function gliding()
	return os.clock() <= glideUntil
end

-- The match drop-in uses the same canopy with a faster fall, so it ends in seconds, not a minute.
-- `lift`: a Rot Glider opened near the ground throws you up on an updraft first.
-- `mode` "steer" (the match drop-in): sail only where you push, at up to `forward`, and straight down with
-- nothing held, so looking around never carries you off the spot you picked on the drop map. The Rot
-- Glider sails where you look on its own.
local glideSteered = false
-- When the last Glide event arrived, so a character swap moments later can tell "this glide is for the
-- body that just appeared" from "this glide belonged to the old body".
local glideStartedAt = -math.huge
-- Frames since the glide opened, and consecutive frames reporting a floor. A drop-in fires as the server
-- teleports the body to drop height, so for a frame or two the client can still report the floor it left:
-- one grounded frame must not read as a landing.
local glideFrames = 0
local glideGroundedFrames = 0
-- TEMPORARY, for Oliver's live check of the drop-in: prints the first frames of a glide to the client
-- console (F9). Remove once the drop is confirmed good.
local GLIDE_TRACE = true

Remotes.Event("Glide").OnClientEvent:Connect(function(duration, fallSpeed, forward, lift, mode)
	if not SafeValue.Number(duration, 1000) then
		return
	end
	glideStartedAt = os.clock()
	glideFrames = 0
	glideGroundedFrames = 0
	glideUntil = os.clock() + math.clamp(duration, 0, 30)
	glideFallSpeed = SafeValue.Number(fallSpeed, 1000) and math.clamp(fallSpeed, 4, 60) or GLIDE_FALL_SPEED
	glideForward = SafeValue.Number(forward, 1000) and math.clamp(forward, 0, 80) or GLIDE_FORWARD
	glideSteered = mode == "steer"
	glideAirborne = false
	glideVelocity = nil
	carry = nil
	if SafeValue.Number(lift, 1000) and lift > 0 and alive() then
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.clamp(lift, 0, 200), velocity.Z)
		Sfx.Play("LaunchWhoosh", 0.1, 0.85)
	end
end)

local function stepGlide(dt)
	if not gliding() or not alive() then
		return
	end
	glideFrames += 1
	local inAir = humanoid.FloorMaterial == Enum.Material.Air
	if GLIDE_TRACE and glideFrames <= 10 then
		print(string.format("[Glide] frame %d floor=%s airborne=%s y=%.1f vy=%.1f cap=%.0f forward=%.0f",
			glideFrames, humanoid.FloorMaterial.Name, tostring(glideAirborne), root.Position.Y,
			root.AssemblyLinearVelocity.Y, glideFallSpeed, glideForward))
	end
	if inAir then
		glideAirborne = true
		glideGroundedFrames = 0
	elseif glideAirborne then
		-- Only a real landing ends it: several frames in a row on a floor, and never in the first moments
		-- of a drop, when the body may still be reported at the pad it was teleported from.
		glideGroundedFrames += 1
		if glideGroundedFrames >= 3 and os.clock() - glideStartedAt > 0.4 then
			glideUntil = 0
			return
		end
	end
	local velocity = root.AssemblyLinearVelocity
	-- The canopy caps how fast you fall: never faster than glideFallSpeed downward. This took math.min
	-- of the two, which is the FASTER of them, so anyone already falling faster than the canopy's speed
	-- had their own fall speed written straight back and dropped like a stone — everyone on the drop-in,
	-- who is doing well over it by the time the canopy opens.
	local fall = math.max(velocity.Y, -glideFallSpeed)
	if glideAirborne and glideForward > 0 then
		-- Sail forward where the camera points (or, steered, where you push), easing toward it so turns
		-- feel like banking.
		local look = camera.CFrame.LookVector
		local heading = Vector3.new(look.X, 0, look.Z)
		heading = heading.Magnitude > 0.05 and heading.Unit or flat(root.CFrame.LookVector).Unit
		local wanted = heading * glideForward
		if glideSteered then
			local push = flat(humanoid.MoveDirection)
			if push.Magnitude > 0.1 then
				heading = push.Unit
				wanted = heading * glideForward * math.min(push.Magnitude, 1)
			else
				wanted = Vector3.zero
			end
		end
		glideVelocity = (glideVelocity or flat(velocity)):Lerp(wanted, math.clamp(dt * 2.5, 0, 1))
		-- `fall` is the cap, worked out once above: the sailing branch wrote the same rule out a
		-- second time, and two copies of a rule are how the first one came to be inverted.
		root.AssemblyLinearVelocity = Vector3.new(glideVelocity.X, fall, glideVelocity.Z)
		-- Face the way you're sailing.
		if heading.Magnitude > 0.05 and wanted.Magnitude > 0 then
			root.CFrame = CFrame.lookAt(root.Position, root.Position + heading)
		end
	elseif velocity.Y < -glideFallSpeed then
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, fall, velocity.Z)
	end
end

--------------------------------------------------------------------------------
-- Launches (Rot Rocket, Launch Pad, Blink Bean, the geyser)
--------------------------------------------------------------------------------

-- A rocket keeps its launch speed but takes its direction from the camera: looking up raises the
-- climb angle (higher, shorter), looking down flattens it (lower, about as far).
local ROCKET_MIN_ANGLE, ROCKET_MAX_ANGLE, ROCKET_PITCH_SHARE = 30, 76, 0.55

local function aimRocket(velocity)
	local speed = velocity.Magnitude
	local horizontal = flat(velocity)
	local baseAngle = math.deg(math.atan2(velocity.Y, math.max(horizontal.Magnitude, 1e-3)))
	local look = camera.CFrame.LookVector
	local pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
	local angle = math.rad(math.clamp(baseAngle + pitch * ROCKET_PITCH_SHARE, ROCKET_MIN_ANGLE, ROCKET_MAX_ANGLE))
	local heading = flat(look)
	heading = heading.Magnitude > 0.05 and heading.Unit or (horizontal.Magnitude > 0.05 and horizontal.Unit or flat(root.CFrame.LookVector).Unit)
	return heading * speed * math.cos(angle) + Vector3.new(0, speed * math.sin(angle), 0)
end

Remotes.Event("Launch").OnClientEvent:Connect(function(velocity, kind)
	if not SafeValue.Vector3(velocity, 2000) or not alive() then
		return
	end
	if kind == "blast" then
		-- An explosion's knockback: capped, it throws you out of a climb or slide, and keeps its speed
		-- through the air like any other launch.
		local horizontal = flat(velocity)
		if horizontal.Magnitude > 60 then
			horizontal = horizontal.Unit * 60
		end
		velocity = horizontal + Vector3.new(0, math.clamp(velocity.Y, -40, 70), 0)
		active = nil
		if slide then
			endSlide(false)
		end
		MovementState.move = nil
		-- Entering Jumping would raise a small knock-up to a full jump (the humanoid applies its own jump
		-- speed over anything slower), so a weak blast only leaves the ground in Freefall.
		local jumpSpeed = humanoid.UseJumpPower and humanoid.JumpPower or math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
		humanoid:ChangeState(velocity.Y >= jumpSpeed and Enum.HumanoidStateType.Jumping or Enum.HumanoidStateType.Freefall)
		root.AssemblyLinearVelocity = velocity
		startCarry(velocity)
		return
	end
	if kind == "blink" then
		-- Out of the dash at speed, with any fall cancelled.
		root.AssemblyLinearVelocity = flat(velocity)
		startCarry(velocity)
		Sfx.Play("LaunchWhoosh", 0.1, 1.35)
		return
	end
	if kind == "rocket" then
		velocity = aimRocket(velocity)
	elseif kind == "pad" then
		-- Thrown along the way you're running, if you are.
		local run = flat(humanoid.MoveDirection)
		if run.Magnitude > 0.1 then
			velocity = run.Unit * flat(velocity).Magnitude + Vector3.new(0, velocity.Y, 0)
		end
	end
	-- Entering the jumping state first stops the humanoid's ground friction eating the launch on the
	-- first frame.
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = velocity
	if kind == "rocket" or kind == "pad" then
		startCarry(velocity)
		Sfx.Play("LaunchWhoosh", 0.1)
	else
		Sfx.Play("Pickup", 0.2)
	end
end)

--------------------------------------------------------------------------------
-- Jump input
--------------------------------------------------------------------------------

local lastJumpRequest = 0
-- A fresh press (not a held key repeating), for the double jump and the slide-jump.
local pressedAt = 0

-- The keys are read directly rather than from InputBegan's `processed` flag: the default controls bind
-- Space and ButtonA through ContextActionService, which marks them processed, so filtering on it would
-- ignore every jump. Typing in a text box (chat) doesn't count.
-- The touch jump button has no key, so its held state is read from the player module, the same way
-- the module itself decides humanoid.Jump each frame.
local function controlsJumping()
	if not controls then
		return false
	end
	local ok, jumping = pcall(function()
		local activeController = controls:GetActiveController()
		if activeController and activeController:GetIsJumping() then
			return true
		end
		local touchJump = controls.touchJumpController
		return touchJump ~= nil and touchJump:GetIsJumping()
	end)
	return ok and jumping == true
end

local function jumpKeyDown()
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
		or controlsJumping()
end

UserInputService.InputBegan:Connect(function(input)
	if (input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA) and not UserInputService:GetFocusedTextBox() then
		pressedAt = os.clock()
	end
end)
-- JumpRequest covers the touch jump button, which has no key to watch.
UserInputService.JumpRequest:Connect(function()
	local now = os.clock()
	if not jumpKeyDown() and now - lastJumpRequest > 0.3 then
		pressedAt = now
	end
	lastJumpRequest = now
end)

local function wantsJump(now)
	return jumpKeyDown() or now - lastJumpRequest < 0.2
end

--------------------------------------------------------------------------------
-- Slide
--------------------------------------------------------------------------------

-- `slide` (declared at the top): { dir, speed, started, runSpeed, airSince, slowFrames, jumpPressedBefore }
local slideReadyAt = 0

function endSlide(jumped)
	local ended = slide
	if not ended then
		return
	end
	slide = nil
	slideReadyAt = os.clock() + SLIDE.Cooldown
	slideEndRemote:FireServer()
	if MovementState.move == "slide" then
		MovementState.move = nil
	end
	applyBodyHeight()
	if jumped and alive() then
		-- Slide-jump: whatever speed the slide had carries through the air.
		local speed = math.max(flat(root.AssemblyLinearVelocity).Magnitude, math.min(ended.speed, humanoid.WalkSpeed))
		startCarry(ended.dir * speed, ended.runSpeed)
	elseif MovementState.crouchHeld and alive() then
		-- Still holding crouch as the slide runs out: settle into the crouch rather than standing up.
		setCrouching(true)
	end
end

-- Starts a slide if everything allows one, and says whether it did. The caller is the CROUCH key
-- (crouchPressed): the slide has no control of its own, so a `false` here becomes a plain crouch and the
-- press is never swallowed.
local function tryStartSlide()
	if slide or MovementState.move or not alive() then
		return false
	end
	local now = os.clock()
	if now < slideReadyAt or not MovementState.sprinting then
		return false
	end
	if humanoid.FloorMaterial == Enum.Material.Air or humanoid.Sit then
		return false
	end
	local velocity = flat(root.AssemblyLinearVelocity)
	local runSpeed = humanoid.WalkSpeed
	if velocity.Magnitude < SLIDE.MinEntryFraction * runSpeed then
		return false
	end
	local floor = groundHit()
	if floor and Parkour.IsExcluded(floor.Instance) then
		return false
	end
	-- Everything but stamina says yes: flash the bar so the refusal reads. You still crouch.
	if not predictSpend(STAMINA.SlideCost, false) then
		MovementState.refusedAt = now
		return false
	end
	slideRemote:FireServer()
	slide = {
		dir = velocity.Unit,
		speed = math.max(velocity.Magnitude, runSpeed) * SLIDE.StartMultiplier,
		started = now,
		runSpeed = runSpeed,
		airSince = nil,
		slowFrames = 0,
		jumpPressedBefore = pressedAt,
	}
	MovementState.move = "slide"
	carry = nil
	-- A slide lowers the body exactly as a crouch does, so you can take one under a gap you couldn't
	-- walk through. The server does the same in MatchService.updateHeight.
	applyBodyHeight()
	Sfx.Play("SlideStart", 0.08)
	return true
end

-- The public request still works (MovementState.RequestSlide), though nothing calls it now that the
-- slide is the crouch key.
MovementState.SlideRequested:Connect(tryStartSlide)

local function stepSlide(dt)
	if not slide then
		return
	end
	if not alive() then
		endSlide(false)
		return
	end
	local now = os.clock()
	local elapsed = now - slide.started
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	if grounded then
		slide.airSince = nil
	elseif not slide.airSince then
		slide.airSince = now
	end

	-- Downhill feeds it, uphill eats it: the ground normal leans the way the ground falls away.
	local ground = grounded and groundHit()
	if ground then
		slide.speed += SLIDE.SlopeGain * workspace.Gravity * flat(ground.Normal):Dot(slide.dir) * dt
	end
	slide.speed = SLIDE.FloorSpeed + (slide.speed - SLIDE.FloorSpeed) * math.exp(-SLIDE.Friction * dt)

	-- A/D bends it.
	local move = controls and controls:GetMoveVector() or Vector3.zero
	if math.abs(move.X) > 0.1 then
		slide.dir = CFrame.Angles(0, -move.X * math.rad(SLIDE.TurnRate) * dt, 0):VectorToWorldSpace(slide.dir)
	end

	-- Stopped by something in the way.
	local actual = flat(root.AssemblyLinearVelocity):Dot(slide.dir)
	if elapsed > 0.2 and actual < 0.35 * math.min(slide.speed, humanoid.WalkSpeed) then
		slide.slowFrames += 1
	else
		slide.slowFrames = 0
	end

	local jumped = pressedAt > slide.jumpPressedBefore or humanoid:GetState() == Enum.HumanoidStateType.Jumping
	if jumped or slide.speed < SLIDE.EndSpeed or elapsed > SLIDE.MaxTime or slide.slowFrames >= 4
		or (slide.airSince and now - slide.airSince > SLIDE.AirGrace) then
		endSlide(jumped)
	end
end

--------------------------------------------------------------------------------
-- Climbing and vaulting
--------------------------------------------------------------------------------

-- `active` (declared at the top) is the move under way: { plan, started }.
local recoveryUntil = 0
local lastGroundY = nil
local groundedAt = 0

local function finishMove()
	local finished = active
	active = nil
	recoveryUntil = os.clock() + PARKOUR.Recovery
	if MovementState.move == finished.plan.kind then
		MovementState.move = nil
	end
	if not alive() then
		return
	end
	root.AssemblyLinearVelocity = finished.plan.exitVelocity
	if finished.plan.kind == "vault" then
		startCarry(finished.plan.exitVelocity)
	end
	if MovementState.crouchHeld then
		setCrouching(true)
	end
	-- Holding jump through a climb would hop straight off the ledge you just got onto.
	if jumpKeyDown() then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		local body = humanoid
		task.delay(0.25, function()
			if body.Parent then
				body:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
			end
		end)
	end
end

local function startMove(plan)
	active = { plan = plan, started = os.clock() }
	MovementState.move = plan.kind
	carry = nil
	-- You stand to climb; if the key is still held you drop back into it when you land (finishMove).
	setCrouching(false, true)
	if slide then
		endSlide(false)
	end
	parkourRemote:FireServer(plan.kind, plan.rise, plan.duration)
	Sfx.Play(plan.kind == "vault" and "Vault" or "Mantle", 0.08)
end

local function stepMove()
	if not active then
		return
	end
	if not alive() then
		active = nil
		MovementState.move = nil
		return
	end
	local plan = active.plan
	local position, done = Parkour.PositionAt(plan, os.clock() - active.started)
	root.CFrame = CFrame.lookAt(position, position + plan.forward)
	root.AssemblyLinearVelocity = Vector3.zero
	if done then
		finishMove()
	end
end

-- Looks for a climb or vault while jump is held (or was just pressed), and starts one.
local function tryParkour(now)
	if active or now < recoveryUntil or not inMatch() or not alive() or gliding() or humanoid.Sit then
		return false
	end
	if not wantsJump(now) then
		return false
	end
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local direction = flat(humanoid.MoveDirection)
	if direction.Magnitude < 0.1 then
		direction = flat(camera.CFrame.LookVector)
	end
	if direction.Magnitude < 0.05 then
		return false
	end
	direction = direction.Unit
	local velocity = flat(root.AssemblyLinearVelocity)
	local speed = math.max(velocity:Dot(direction), 0)
	local recentlyGrounded = grounded or now - groundedAt < 0.35
	local plan = Parkour.Find(character, direction, {
		groundY = lastGroundY,
		speed = speed,
		grounded = grounded,
		allowVault = recentlyGrounded,
		exhausted = MovementState.exhausted and not MovementState.rush,
	})
	if not plan then
		return false
	end
	-- On the move, a climb only takes over where the jump itself wouldn't clear the ledge: running onto a
	-- crate or a step stays a plain jump that keeps its speed, not a slow pull-up. Standing still, a
	-- climb is always the smoother way up.
	if plan.kind == "mantle" and speed >= 8 then
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
		local jumpHeight = humanoid.UseJumpPower and humanoid.JumpPower ^ 2 / (2 * workspace.Gravity) or humanoid.JumpHeight
		local rising = math.max(root.AssemblyLinearVelocity.Y, 0)
		local apex = grounded and feet + jumpHeight or feet + rising * rising / (2 * workspace.Gravity)
		if plan.topY < apex - 0.6 then
			return false
		end
	end
	-- In the air, a vault only takes over where the jump itself would NOT clear the obstacle (the same
	-- rule as the climb above): a knee-high rail you jumped at early stays a free hop, no stamina, no
	-- pose. A window always takes over: its pane is in the plan's clearance box, and a body cannot fit a
	-- window at the top of a jump anyway. Cleared means the feet are still above the top, with margin,
	-- both where the body reaches the near edge and where it leaves the far one.
	if plan.kind == "vault" and not grounded and not (plan.panes and #plan.panes > 0) then
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
		local velocity = root.AssemblyLinearVelocity
		local toward = flat(velocity):Dot(plan.forward)
		if toward > 1 then
			local near = math.max((flat(plan.points[2]) - flat(root.Position)):Dot(plan.forward), 0)
			local far = near + plan.depth + root.Size.Z + 0.6
			local clears = true
			for _, distance in ipairs({ near, far }) do
				local t = distance / toward
				if feet + velocity.Y * t - 0.5 * workspace.Gravity * t * t < plan.topY + 0.3 then
					clears = false
				end
			end
			if clears then
				return false
			end
		end
	end
	if not predictSpend(plan.cost, plan.kind == "mantle") then
		plan = Parkour.Find(character, direction, { groundY = lastGroundY, speed = speed, allowVault = false,
			exhausted = MovementState.exhausted })
		if not plan or not predictSpend(plan.cost, true) then
			MovementState.refusedAt = now
			return false
		end
	end
	startMove(plan)
	return true
end

--------------------------------------------------------------------------------
-- Bounce Boots: one mid-air double jump per airtime
--------------------------------------------------------------------------------

-- The second jump's launch speed as a share of the boots' own jump. At 0.85 a double jump at the apex
-- reached 42 studs, over two-storey roofs; at 0.6 it adds about 7 to the boots' 21, which reaches
-- nothing a single boots jump plus a climb couldn't, and mostly buys distance and a second chance.
local DOUBLE_JUMP_SHARE = 0.6
local doubleJumpUsed = false
local handledPress = 0

local function tryDoubleJump(now)
	if pressedAt <= handledPress or now - pressedAt > 0.15 then
		return
	end
	handledPress = pressedAt
	if doubleJumpUsed or active or gliding() or not alive() or humanoid.Sit or humanoid.FloorMaterial ~= Enum.Material.Air then
		return
	end
	if now - groundedAt < 0.12 then
		return
	end
	local untilTime = player:GetAttribute("BounceBootsUntil")
	if type(untilTime) ~= "number" or workspace:GetServerTimeNow() > untilTime then
		return
	end
	doubleJumpUsed = true
	local jumpSpeed = humanoid.UseJumpPower and humanoid.JumpPower or math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
	-- No ChangeState(Jumping) here: entering Jumping makes the humanoid apply its own full jump speed
	-- over anything slower, which turned this into a second full boots jump (42 studs, measured).
	-- Already in the air, a plain velocity write is enough.
	local velocity = root.AssemblyLinearVelocity
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, jumpSpeed * DOUBLE_JUMP_SHARE, velocity.Z)
	Sfx.Play("DoubleJump", 0.08)
end

--------------------------------------------------------------------------------
-- Crouch
--------------------------------------------------------------------------------

-- The state is the server's (MatchService.SetCrouching holds the speed factor and the HipHeight); this
-- predicts the height locally so the body drops on the same frame as the key, and eases the camera and
-- the gun down with it. Shared/CrouchAnimation draws the fold, here and on every other client.
local crouchHeld = false
local crouchReadyAt = 0
-- How long the server has to agree that we are crouching before we give up and stand.
local CROUCH_SETTLE = 1.2
local crouchChangedAt = -math.huge
local baseHipHeight = nil

-- The body's height, predicted locally so it drops on the same frame as the key rather than a round trip
-- later. MatchService.updateHeight is the same rule on the server: LOW while crouching or sliding.
function applyBodyHeight()
	if not alive() then
		return
	end
	if baseHipHeight == nil then
		baseHipHeight = humanoid:GetAttribute("BaseHipHeight") or humanoid.HipHeight
	end
	local low = MovementState.crouching or slide ~= nil
	humanoid.HipHeight = low and math.max(baseHipHeight * CROUCH.HipScale, CROUCH.MinHipHeight) or baseHipHeight
end

-- Split out because the reconcile below has to put the body back without telling the server anything
-- (it is the server it is agreeing with).
local function applyCrouchHeight(value)
	MovementState.crouching = value
	crouchChangedAt = os.clock()
	applyBodyHeight()
end

-- `keepReady` suspends a crouch without arming its cooldown, for the climb and vault that stand you up
-- and put you straight back down again (finishMove); a quick vault lands inside those 0.15s.
function setCrouching(value, keepReady)
	value = value == true
	if MovementState.crouching == value then
		return
	end
	if value and (not alive() or humanoid.Sit or active or os.clock() < crouchReadyAt) then
		return
	end
	crouchRemote:FireServer(value)
	if value then
		-- Crouching and sprinting cancel each other, the way sprinting and aiming do.
		MovementState._RequestSprintOff()
	elseif not keepReady then
		crouchReadyAt = os.clock() + CROUCH.Cooldown
	end
	applyCrouchHeight(value)
end

-- How far into the crouch the body is, on the same easing the animation uses.
local function crouchLevel()
	if MovementState.crouching then
		return CrouchAnimation.Weight(os.clock() - crouchChangedAt, true)
	end
	return CrouchAnimation.Weight(os.clock() - crouchChangedAt, false)
end

-- ONE KEY, TWO MOVES: crouch while sprinting and you slide; crouch otherwise and you crouch. The slide
-- has no control of its own. Every case, decided deliberately rather than left to fall out of the order:
--
--   sprinting, at speed, on the ground   -> slide. When it ends, you are left CROUCHING if the key is
--                                           still held (endSlide), because standing up would be taking
--                                           the player's input away from them.
--   sprinting but too slow, or airborne, or on ground a slide is refused on
--                                        -> plain crouch. The press is never swallowed.
--   sprint just ended, or stamina just ran out mid-stride
--                                        -> plain crouch: by the time the key is read the sprint is
--                                           already off, and a crouch is what "crouch" should give you.
--   out of stamina for the slide         -> the bar flashes the refusal AND you crouch. Getting neither
--                                           reads as the game ignoring the button.
--   already sliding                      -> nothing. The slide is running; crouching on top of it would
--                                           multiply its ceiling by the crouch factor and drop it below
--                                           walking pace. It settles into a crouch by itself.
local function crouchPressed()
	if slide then
		return
	end
	if tryStartSlide() then
		return
	end
	setCrouching(true)
end

Settings.Bind("BRR_Crouch", "Crouch", function(_, inputState, inputObject)
	-- A toggle by setting, and always a toggle on touch (a thumb can't hold it and shoot).
	local toggles = Settings.Get("CrouchToggle") == true
		or (inputObject ~= nil and inputObject.UserInputType == Enum.UserInputType.Touch)
	if inputState == Enum.UserInputState.Begin then
		if toggles and (crouchHeld or MovementState.crouching) then
			crouchHeld = false
			MovementState.crouchHeld = false
			setCrouching(false)
			return Enum.ContextActionResult.Pass
		end
		crouchHeld = true
		MovementState.crouchHeld = true
		crouchPressed()
	elseif not toggles and (inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel) then
		crouchHeld = false
		MovementState.crouchHeld = false
		setCrouching(false)
	end
	return Enum.ContextActionResult.Pass
-- Touch: this button IS the slide button now — the slide has no control of its own, so it takes over the
-- "slide" slot in TouchControls and the free CAS position under PET. Without a button here a phone
-- player could neither crouch NOR slide. The branch above that makes touch always a toggle exists
-- precisely because a thumb can't hold this and shoot.
--
-- The slot is named explicitly because TouchControls maps action names to slots by a table it owns, and
-- it has no entry for BRR_Crouch: an unnamed slot would simply not be drawn once that system is on.
end, { title = "CROUCH", position = UDim2.new(1, -360, 1, -280), slot = "slide" }, Enum.KeyCode.ButtonR3)

--------------------------------------------------------------------------------
-- Quick movement item
--------------------------------------------------------------------------------

-- Uses the first movement item you carry without switching off your gun (WeaponService.StartUse with
-- a slot index; the server checks the slot really holds a movement item).
local useRemote = Remotes.Event("UseSelected")

local function firstMovementSlot()
	if not loadout or type(loadout.slots) ~= "table" then
		return nil
	end
	for index = 1, 8 do
		local slot = loadout.slots[index]
		local item = type(slot) == "table" and slot.kind == "item" and ItemData.Get(slot.id)
		if item and item.kind == "movement" then
			return index
		end
	end
	return nil
end

Settings.Bind("BRR_MovementItem", "MovementItem", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin or not inMatch() or not alive() or player:GetAttribute("MenuOpen") then
		return Enum.ContextActionResult.Pass
	end
	local index = firstMovementSlot()
	if index then
		useRemote:FireServer(nil, index)
	end
	return Enum.ContextActionResult.Pass
-- Touch: (1, -470, 1, -280), above SLIDE (1, -470, 1, -180) in the 4th column left of PET/CAM; the full
-- button map is beside the Slide bind in CombatClient. (380 up would sit at the top edge of a 390-tall phone.)
end, { title = "MOVE", position = UDim2.new(1, -470, 1, -280) }, Enum.KeyCode.DPadDown)

--------------------------------------------------------------------------------
-- The frame
--------------------------------------------------------------------------------

-- While a slide runs this holds the move vector (after the player module has written it); during a
-- climb or vault it holds it still.
RunService:BindToRenderStep("BRR_MovementSteer", Enum.RenderPriority.Input.Value + 1, function()
	if not alive() then
		return
	end
	if slide then
		local ceiling = math.max(humanoid.WalkSpeed, 1)
		humanoid:Move(slide.dir * math.clamp(slide.speed / ceiling, 0, 1), false)
	elseif active then
		humanoid:Move(Vector3.zero, false)
	end
end)

local cameraDrop = 0

RunService.Heartbeat:Connect(function(delta)
	local dt = math.min(delta, 0.1)
	local now = os.clock()
	MovementState.inMatch = inMatch()
	stepStamina(dt)
	if not alive() then
		slide, active, carry = nil, nil, nil
		MovementState.move = nil
		MovementState.dip = 0
		return
	end

	if humanoid.FloorMaterial ~= Enum.Material.Air and not active then
		lastGroundY = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
		groundedAt = now
		doubleJumpUsed = false
	end

	stepMove()
	if not active then
		stepSlide(dt)
		if not tryParkour(now) then
			tryDoubleJump(now)
		end
	end
	stepCarry(dt, active ~= nil or gliding())
	stepGlide(dt)

	-- The view drops into a slide and dips through a climb or vault; the gun follows (slideDip).
	local wantedDip = (MovementState.move == "slide" and 1) or (MovementState.move == "vault" and 0.8)
		or (MovementState.move == "mantle" and 0.65) or 0
	MovementState.dip += (wantedDip - MovementState.dip) * math.clamp(dt * (wantedDip > MovementState.dip and 12 or 5), 0, 1)
	-- Sprint stands you up, the way it does in anything else with a crouch. Without this the two can both
	-- be on at once: the server drops the sprint and keeps the crouch speed, while the client goes on
	-- predicting a sprint's stamina drain for a crouch-walk that is costing nothing.
	if MovementState.crouching and MovementState.sprinting then
		crouchHeld = false
		MovementState.crouchHeld = false
		setCrouching(false)
	end

	-- The server has the last word on crouching. If it never took ours — refused, rate-limited, or the
	-- body changed underneath us — stand back up rather than walk around lowered (a smaller target) at
	-- a speed the server never cut. One way only: the server can end our crouch, never start one.
	if MovementState.crouching and now - crouchChangedAt > CROUCH_SETTLE
		and character:GetAttribute("Crouching") ~= true
	then
		crouchHeld = false
		MovementState.crouchHeld = false
		applyCrouchHeight(false)
		crouchReadyAt = now + CROUCH.Cooldown
	end
	local crouched = crouchLevel()
	MovementState.dip = math.max(MovementState.dip, crouched * CROUCH.GunDip)
	local wantedDrop = math.max(MovementState.move == "slide" and SLIDE.CameraDrop or 0, crouched * CROUCH.CameraDrop)
	cameraDrop += (wantedDrop - cameraDrop) * math.clamp(dt * (wantedDrop > cameraDrop and 14 or 6), 0, 1)
	if cameraDrop > 0.01 or humanoid.CameraOffset.Y ~= 0 then
		humanoid.CameraOffset = Vector3.new(0, cameraDrop > 0.01 and -cameraDrop or 0, 0)
	end
end)

local function onCharacter(newCharacter)
	-- EVERY reset happens before the WaitForChilds below, because those YIELD. The match drop-in fires
	-- its Glide within milliseconds of the character appearing, so a reset after the yield would wipe the
	-- glide that had already arrived and drop the player at full speed under an open canopy. (That is
	-- exactly what happened when this moved out of CombatClient, where the reset was the first line.)
	slide, active, carry = nil, nil, nil
	-- ...and a glide that arrived in the last couple of seconds belongs to THIS body (the drop-in fires as
	-- the character appears), so it is never reset here. Belt and braces with the ordering above.
	if os.clock() - glideStartedAt > 2 then
		glideUntil = 0
		glideVelocity = nil
		glideAirborne = false
	end
	lastGroundY = nil
	cameraDrop = 0
	MovementState.move = nil
	MovementState.dip = 0
	MovementState.crouching = false
	MovementState.crouchHeld = false
	crouchHeld = false
	baseHipHeight = nil

	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid", 10)
	root = newCharacter:WaitForChild("HumanoidRootPart", 10)
	-- A sprint toggled on (touch RUN, stick click) never carries over to a new body, a death or a seat.
	MovementState._RequestSprintOff()
	if humanoid then
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		humanoid.Died:Connect(MovementState._RequestSprintOff)
		humanoid.Seated:Connect(function(seated)
			if seated then
				MovementState._RequestSprintOff()
				crouchHeld = false
				MovementState.crouchHeld = false
				setCrouching(false)
			end
		end)
	end
end

player:GetAttributeChangedSignal("MenuOpen"):Connect(function()
	if player:GetAttribute("MenuOpen") then
		MovementState._RequestSprintOff()
		crouchHeld = false
		MovementState.crouchHeld = false
		setCrouching(false)
	end
end)

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

--------------------------------------------------------------------------------
-- Poses on every body, and the sounds of other people's moves
--------------------------------------------------------------------------------

local POSE_DISTANCE = 250
local HEAR_CUES = { slide = "SlideStart", mantle = "Mantle", vault = "Vault" }
-- Every body with a Humanoid is watched (false until it first poses); `posing` holds only the ones
-- sliding, climbing, vaulting or crouching (and the ones still easing out of it), so the per-frame loop
-- doesn't visit every bot in the match. character -> {
--   joints, root, weight, kind,            the slide/climb/vault pose
--   crouchOn, crouchAt, crouchTravel, stride, lastPosition   the crouch animation
-- }
local posed = {}
local posing = {}

-- Every bot is a PHYSICS rig (CreateHumanoidModelFromDescription): its joints are AnimationConstraints
-- driven by torque, not Motor6Ds, so a leg we fold sags back under gravity and the pose reads wrong from
-- outside — which is the only way anyone ever sees a bot. Kinematic joints hold the Transform exactly.
-- Done per body while it is posed and handed back the way we found it, so nothing else that leans on
-- those joints (a death ragdoll, say) is changed by our having been here. Client-side only: a property
-- set here never leaves this machine.
local function holdJoints(joints)
	local restore = nil
	for _, joint in pairs(joints) do
		if joint:IsA("AnimationConstraint") and not joint.IsKinematic then
			restore = restore or {}
			restore[joint] = true
			pcall(function()
				joint.IsKinematic = true
			end)
		end
	end
	return restore
end

local function releaseJoints(restore)
	for joint in pairs(restore or {}) do
		if joint.Parent then
			pcall(function()
				joint.IsKinematic = false
			end)
		end
	end
end

local function watchCharacter(model)
	if not model:IsA("Model") or posed[model] ~= nil then
		return
	end
	local body = model:FindFirstChildOfClass("Humanoid")
	if not body then
		return
	end
	posed[model] = false
	model:GetAttributeChangedSignal("Parkour"):Connect(function()
		local kind = model:GetAttribute("Parkour")
		if kind then
			posing[model] = true
		end
		local cue = kind and HEAR_CUES[kind]
		local bodyRoot = model:FindFirstChild("HumanoidRootPart")
		if cue and model ~= character and bodyRoot then
			Sfx.PlayAt(cue, bodyRoot.Position, 0.08)
		end
	end)
	-- Crouching is a state, not a moment: it can already be on by the time this body is first seen
	-- (a bot that spawned crouched, someone who crouched before we streamed them in), so the attribute
	-- is read as well as watched.
	model:GetAttributeChangedSignal("Crouching"):Connect(function()
		if model:GetAttribute("Crouching") then
			posing[model] = true
		end
	end)
	if model:GetAttribute("Crouching") then
		posing[model] = true
	end
end

task.spawn(function()
	while true do
		for _, child in ipairs(workspace:GetChildren()) do
			watchCharacter(child)
		end
		for model in pairs(posed) do
			if not model.Parent then
				posed[model] = nil
				posing[model] = nil
			end
		end
		task.wait(1)
	end
end)

-- Bound just AFTER the character update rather than to Stepped, because that is the one place a pose
-- written onto a joint survives the frame: the Animator evaluates every playing animation as part of the
-- character's own render step, and anything written before that is simply overwritten. Poses are drawn
-- per client for every body in sight, so this runs for bots and other players too.
RunService:BindToRenderStep("BRR_MovementPoses", Enum.RenderPriority.Character.Value + 1, function(delta)
	local dt = math.min(delta, 0.1)
	local now = os.clock()
	local focus = camera.CFrame.Position
	-- Our own body animates from the local state, before the server's attributes come back.
	if character and posed[character] ~= nil and (MovementState.move or MovementState.crouching) then
		posing[character] = true
	end
	for model in pairs(posing) do
		local entry = posed[model]
		local isSelf = model == character
		local kind = (isSelf and MovementState.move) or model:GetAttribute("Parkour")
		local crouchOn = (isSelf and MovementState.crouching) or model:GetAttribute("Crouching") == true
		if (kind or crouchOn) and not entry then
			local joints = model.Parent and Parkour.PoseJoints(model)
			if joints then
				entry = {
					joints = joints, root = model:FindFirstChild("HumanoidRootPart"), weight = 0, kind = kind,
					body = model:FindFirstChildOfClass("Humanoid"),
					segments = CrouchAnimation.Segments(model),
					crouchOn = false, crouchAt = -math.huge, phase = 0,
					hold = holdJoints(joints),
					-- Roblox's own character sounds live here. Bots don't have them (the default sound
					-- script only runs for player characters), so this is nil for them and the block below
					-- simply does nothing.
					steps = (function()
						local part = model:FindFirstChild("HumanoidRootPart")
						local sound = part and part:FindFirstChild("Running")
						return sound and sound:IsA("Sound") and sound or nil
					end)(),
				}
				posed[model] = entry
			else
				posing[model] = nil
			end
		end
		if entry then
			if kind then
				entry.kind = kind
			end
			entry.weight += ((kind and 1 or 0) - entry.weight) * math.clamp(dt * (kind and 14 or 9), 0, 1)

			-- Crouch: the cycle is driven by how far the body has actually travelled, not by the clock,
			-- so the feet stay planted whatever the speed.
			if crouchOn ~= entry.crouchOn then
				entry.crouchOn, entry.crouchAt = crouchOn, now
			end
			-- Crouching is quiet, for whoever is listening. The default sound script sets this volume on
			-- state changes, so it is written every frame while the crouch lasts and handed back exactly as
			-- found when it ends — never left turned down on a body that has stood up.
			if entry.steps and entry.steps.Parent then
				if crouchOn then
					entry.loudness = entry.loudness or entry.steps.Volume
					entry.steps.Volume = entry.loudness * CROUCH.StepVolume
				elseif entry.loudness then
					entry.steps.Volume = entry.loudness
					entry.loudness = nil
				end
			end
			local crouchWeight = CrouchAnimation.Weight(now - entry.crouchAt, entry.crouchOn)
			-- How deep this body is sitting, from its own HipHeight against the one it stands at, so the
			-- legs fold exactly as far as MatchService lowered it (a bot, a scaled avatar, a retuned
			-- HipScale: all the same code).
			local drop, crouchSpeed = 0, nil
			if entry.body then
				drop = (entry.body:GetAttribute("BaseHipHeight") or entry.body.HipHeight) - entry.body.HipHeight
				crouchSpeed = entry.body.WalkSpeed
			end
			if drop <= 0.05 and entry.body then
				-- Nothing has lowered it yet (the crouch is still on its way to the server, or this is a
				-- body we only just started watching), so its HipHeight IS the standing one: fold to the
				-- depth the config asks for rather than wait on the round trip.
				drop = entry.body.HipHeight * (1 - CROUCH.HipScale)
			end
			if not crouchSpeed or crouchSpeed < 1 then
				crouchSpeed = MatchConfig.BaseWalkSpeed * CROUCH.SpeedMultiplier
			end
			local depth = CrouchAnimation.Depth(entry.segments, drop)
			local stride = CrouchAnimation.Stride(entry.segments)
			local speed = 0
			local position = entry.root and entry.root.Parent and entry.root.Position
			if position then
				if entry.lastPosition then
					local moved = (Vector3.new(position.X, 0, position.Z)
						- Vector3.new(entry.lastPosition.X, 0, entry.lastPosition.Z)).Magnitude
					speed = moved / math.max(dt, 1e-3)
					if crouchWeight > 0 then
						entry.phase = CrouchAnimation.Advance(entry.phase, moved, stride,
							CrouchAnimation.Walk(speed, crouchSpeed))
					end
				end
				entry.lastPosition = position
			end

			local done = entry.weight < 0.02 and not kind and crouchWeight <= 0 and not crouchOn
			if done then
				releaseJoints(entry.hold)
				if entry.loudness and entry.steps and entry.steps.Parent then
					entry.steps.Volume = entry.loudness
				end
				posed[model] = model.Parent and false or nil
				posing[model] = nil
			elseif entry.root and entry.root.Parent and (entry.root.Position - focus).Magnitude < POSE_DISTANCE then
				-- A climb or vault takes the body over from the crouch while it runs.
				if entry.weight > 0.02 then
					Parkour.ApplyPose(entry.joints, entry.kind, entry.weight)
				elseif crouchOn or crouchWeight > 0.01 then
					-- `crouchOn` is in that test because the eased weight is still 0 on the first frame of
					-- a crouch, while the hips are already down: one frame with the legs unfolded is one
					-- frame with the feet through the floor.
					-- The pose is built at full depth and Apply does the blending, so easing in and out
					-- lerps from whatever the Animator is playing. (Scaling the ANGLES by the weight
					-- instead would blend from the rig's rest pose, and the legs would snap out of the
					-- walk the moment a crouch started.)
					CrouchAnimation.Apply(entry.joints, CrouchAnimation.Pose({
						phase = entry.phase,
						walk = CrouchAnimation.Walk(speed, crouchSpeed),
						segments = entry.segments,
						depth = depth,
						stride = stride,
						clock = now,
					}), crouchWeight, crouchOn and 1 or 0)
				end
			end
		elseif not kind and not crouchOn then
			posing[model] = nil
		end
	end
end)
