-- The gunner's first-person view of a vehicle's turret (Oliver 09-24: "make the car guns controllable
-- by a gunner seat which has first-person animations and a working sight").
--
--   local view = GunnerView.Start(vehicle, spec, options)   -> view, or nil if the mount can't carry one
--   view:Update(dt, state)   state = { ammo, magazine, ready } -> once a frame, from VehicleWeaponClient
--   view:Fired()             the local shot went (the gun kicks, the view shakes, the hands ride it)
--   view:AimPoint()          -> the world point the server is to fire through: along the barrel as it is
--   view.yaw, view.pitch     the mount's angles now (degrees), for the aim remote and the HUD
--   view:Stop()              the normal camera back, the arms gone, the body shown
--
-- WHAT YOU SEE. The camera sits at the gunner's eye (VehicleModels' GunnerEye marker on TurretYaw) and
-- looks along the barrel: it rides the turret round and tips with it (a lobbing mortar's view instead
-- follows where its bomb will come down, so the ground it is ranging on stays on the screen). The
-- mouse (or the right stick, or a drag on a touch screen) turns the TURRET, at most `slew` degrees a
-- second, and the view goes with it. Aiming down the sight (right mouse, L2, the AIM button) moves the
-- eye to the gun's own sight (GunnerSight: iron sights on the machine guns, the launcher's side sight,
-- the mortar's) and narrows the view.
--
-- THE ARMS are the player's own (Viewmodel.Arms: the avatar's arms, colours and shirt), their palms on
-- the gun's handles (GripR, GripL), posed by the viewmodel's own two-bone reach every frame, so when the
-- gun kicks or tips the hands go with it. While the mount is not ready -- run dry, or a belt too hot --
-- the right hand goes to load it (ReloadHand: the ammo box, the spare rockets, the bombs) and back.
--
-- THE SIGHT shows exactly where the shot will land. The barrel's ray is worked out from the mount as it
-- is swung now (VehicleWeaponData.Turn, the same maths the server's VehicleWeaponData.Solve uses), and
-- the aim sent to the server is a point far along that very ray, so the server fires along it. A bullet
-- is traced along the ray; a rocket or a grenade is flown along Ballistics.RoundState (drop and all,
-- the same function the server's round flies by), segment by segment, until it meets something. That
-- point, projected onto the screen, is the ring; the small cross is the middle of the view. The two
-- sit together at range and part close in (the eye is above the bore) and wherever a round drops.
--
-- tools/gunner_sight_check.py runs this module's PURE block against the real VehicleModels mounts and
-- VehicleWeaponData.Solve; tools/gunner_fp_gallery.lua shows it in Studio.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))

local GunnerView = {}
GunnerView.__index = GunnerView

-- PURE BEGIN (plain Lua and Vector3/CFrame arithmetic; tools/gunner_sight_check.py runs it)
local Pure = {}

-- How far the view narrows aiming down each kind of sight, as a share of the field of view.
Pure.Zoom = { iron = 0.62, scope = 0.42, lob = 0.55 }
-- What a shot does to the gun (degrees of kick up, studs back) and to the view (degrees of shake).
Pure.Kick = {
	hitscan = { pitch = 1.1, back = 0.07, shake = 0.35 },
	heavy = { pitch = 1.6, back = 0.1, shake = 0.5 },
	rocket = { pitch = 4.5, back = 0.22, shake = 1.2 },
	grenade = { pitch = 2.6, back = 0.14, shake = 0.8 },
	lob = { pitch = 3.5, back = 0.18, shake = 1.0 },
}
-- Degrees the view turns per pixel of mouse at 1x sensitivity, and per second at full stick.
Pure.MouseDegrees = 0.22
Pure.StickDegrees = 150
Pure.TouchDegrees = 0.3
-- The stick's response: past a dead zone, the deflection to the power StickCurve; held hard over for
-- StickRampTime seconds it turns StickRamp times as fast.
Pure.StickDeadZone = 0.12
Pure.StickCurve = 1.8
Pure.StickRamp = 1.6
Pure.StickRampTime = 0.5
function Pure.stickCurve(v)
	local m = math.abs(v)
	if m < Pure.StickDeadZone then
		return 0
	end
	m = (m - Pure.StickDeadZone) / (1 - Pure.StickDeadZone)
	return (v > 0 and 1 or -1) * math.min(1, m) ^ Pure.StickCurve
end

-- Whether a spec lobs its round (the mortar): a grenade that can't fire below level.
function Pure.lobs(spec)
	return spec.kind == "round" and spec.projectile == "grenade" and spec.pitchMin >= 0
end

function Pure.sightKind(spec)
	if Pure.lobs(spec) then
		return "lob"
	end
	return spec.projectile == "rocket" and "scope" or "iron"
end

function Pure.kickOf(spec)
	if Pure.lobs(spec) then
		return Pure.Kick.lob
	end
	if spec.kind == "round" then
		return Pure.Kick[spec.projectile] or Pure.Kick.grenade
	end
	return spec.damageClass == "heavy" and Pure.Kick.heavy or Pure.Kick.hitscan
end

-- A wanted look (degrees) held inside the mount's arc: yaw to +-yawLimit (all round wraps), pitch to
-- the floor at that yaw (the front guard's, inside its arc) and pitchMax.
function Pure.clampLook(spec, yaw, pitch)
	if spec.yawLimit >= 180 then
		yaw = (yaw + 180) % 360 - 180
	else
		yaw = math.clamp(yaw, -spec.yawLimit, spec.yawLimit)
	end
	local floor = math.deg(VehicleWeaponData.PitchFloor(spec, math.rad(yaw)))
	return yaw, math.clamp(pitch, floor, spec.pitchMax)
end

-- The turret's angle moved toward the wanted one by at most `step` degrees, the short way round.
function Pure.slew(from, to, step, wraps)
	local delta = to - from
	if wraps then
		delta = (delta + 180) % 360 - 180
	end
	if math.abs(delta) <= step then
		return to
	end
	local out = from + (delta > 0 and step or -step)
	if wraps then
		out = (out + 180) % 360 - 180
	end
	return out
end

-- The mount's angle following the wanted one (Oliver 09-24: "the mounted guns rotation needs to be made
-- smoother"): a critically damped spring (natural frequency `omega`) held to the mount's top speed and
-- acceleration, which brakes in time to stop ON the wanted angle -- so a flick never overshoots, the arc's
-- limit (the wanted angle is clamped to it) is eased into rather than hit, and it settles softly.
-- Sub-stepped at 1/240 s: the same motion at any frame rate. Returns the angle and its velocity (deg/s).
Pure.FollowOmega = 16
function Pure.follow(value, velocity, target, dt, maxSpeed, maxAccel, wraps, omega)
	omega = omega or Pure.FollowOmega
	local left = math.min(dt, 0.1)
	while left > 1e-6 do
		local h = math.min(left, 1 / 240)
		local delta = target - value
		if wraps then
			delta = (delta + 180) % 360 - 180
		end
		local accel = omega * omega * delta - 2 * omega * velocity
		-- Moving toward the target and no further to go than it takes to stop: brake at full.
		if delta * velocity > 0 and velocity * velocity / (2 * maxAccel) >= math.abs(delta) then
			accel = -velocity * velocity / (2 * math.abs(delta) + 1e-6) * (velocity > 0 and 1 or -1)
		end
		accel = math.clamp(accel, -maxAccel, maxAccel)
		velocity = math.clamp(velocity + accel * h, -maxSpeed, maxSpeed)
		local stepTaken = velocity * h
		-- Never step past the target.
		if (delta > 0 and stepTaken > delta) or (delta < 0 and stepTaken < delta) then
			stepTaken = delta
			velocity = 0
		end
		value += stepTaken
		left -= h
	end
	if wraps then
		value = (value + 180) % 360 - 180
	end
	return value, velocity
end

-- The barrel's ray at (yaw, pitch) degrees, world space: `rest` the yaw pivot's frame at rest,
-- `pivot` the pitch pivot and `muzzle` the muzzle as VehicleWeaponData.Solve takes them.
function Pure.barrel(rest, pivot, muzzle, yaw, pitch)
	local y, p = math.rad(yaw), math.rad(pitch)
	local origin = rest:PointToWorldSpace(VehicleWeaponData.Turn(pivot, y, 0) + VehicleWeaponData.Turn(muzzle, y, p))
	local direction = rest:VectorToWorldSpace(VehicleWeaponData.Turn(Vector3.new(0, 0, -1), y, p))
	return origin, direction
end

-- Where a shot along (origin, direction) comes down. `cast(from, to)` returns the first hit's position
-- or nil. A bullet is one cast out to the spec's range; a round flies Ballistics.RoundState (boost,
-- sustainer and drop, the server's own flight) in `step`-second pieces until it meets something or
-- its time is up. Returns the point and whether it was a hit (false: the end of its reach, in the air).
function Pure.impact(spec, round, origin, direction, gravity, cast, step)
	if spec.kind ~= "round" or not round then
		local reach = origin + direction * (spec.range or 400)
		local hit = cast(origin, reach)
		return hit or reach, hit ~= nil
	end
	step = step or 0.04
	local last = origin
	local t = 0
	local maxTime = round.maxTime or 3
	while t < maxTime do
		t = math.min(maxTime, t + step)
		local position = Ballistics.RoundState(round, origin, direction, gravity, t)
		local hit = cast(last, position)
		if hit then
			return hit, true
		end
		last = position
	end
	return last, false
end

-- A damped spring toward zero, one sub-step: `k` stiffness, `c` damping.
function Pure.spring(value, velocity, dt, k, c)
	velocity = velocity + (-k * value - c * velocity) * dt
	return value + velocity * dt, velocity
end

function Pure.smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end
-- PURE END

GunnerView.Pure = Pure

local player = Players.LocalPlayer

local function settings()
	local ok, Settings = pcall(function()
		return require(script.Parent:WaitForChild("Settings", 2))
	end)
	return ok and type(Settings) == "table" and Settings or nil
end

local function jointOf(part)
	local joint = part and part:FindFirstChild("Joint")
	return joint and joint:IsA("Motor6D") and joint or nil
end

-- Everything a sight's trace must pass through: the vehicle and whoever rides in it, and the game's
-- own non-solid folders (as the server's bullet, VehicleWeapons).
local function sightParams(vehicle)
	local filter = { vehicle }
	for _, child in ipairs(vehicle:GetChildren()) do
		if (child:IsA("Seat") or child:IsA("VehicleSeat")) and child.Occupant and child.Occupant.Parent then
			table.insert(filter, child.Occupant.Parent)
		end
	end
	for _, name in ipairs({ "Loot", "Effects", "DeathFx" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	local camera = workspace.CurrentCamera
	table.insert(filter, camera)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = filter
	return params
end

local function makeGui(parent)
	local gui = Instance.new("ScreenGui")
	gui.Name = "GunnerSight"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 2
	gui.Parent = parent or player:WaitForChild("PlayerGui")
	-- The middle of the view: a small open cross.
	local cross = Instance.new("Frame")
	cross.Name = "Cross"
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromScale(0.5, 0.5)
	cross.Size = UDim2.fromOffset(22, 22)
	cross.BackgroundTransparency = 1
	cross.Parent = gui
	for index, spec in ipairs({ { 0, -7, 2, 6 }, { 0, 7, 2, 6 }, { -7, 0, 6, 2 }, { 7, 0, 6, 2 } }) do
		local tick = Instance.new("Frame")
		tick.Name = "Tick" .. index
		tick.AnchorPoint = Vector2.new(0.5, 0.5)
		tick.Position = UDim2.new(0.5, spec[1], 0.5, spec[2])
		tick.Size = UDim2.fromOffset(spec[3], spec[4])
		tick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		tick.BackgroundTransparency = 0.25
		tick.BorderSizePixel = 0
		tick.Parent = cross
	end
	-- Where the shot lands: a ring with a dot, and (for a round) its range under it.
	local ring = Instance.new("Frame")
	ring.Name = "Impact"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Visible = false -- until the first frame has placed it
	ring.Size = UDim2.fromOffset(20, 20)
	ring.BackgroundTransparency = 1
	ring.Parent = gui
	Instance.new("UICorner", ring).CornerRadius = UDim.new(1, 0)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(255, 214, 90)
	stroke.Parent = ring
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(4, 4)
	dot.BackgroundColor3 = Color3.fromRGB(255, 214, 90)
	dot.BorderSizePixel = 0
	dot.Parent = ring
	Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
	local range = Instance.new("TextLabel")
	range.Name = "Range"
	range.AnchorPoint = Vector2.new(0.5, 0)
	range.Position = UDim2.new(0.5, 0, 1, 6)
	range.Size = UDim2.fromOffset(90, 14)
	range.BackgroundTransparency = 1
	range.Font = Enum.Font.GothamBold
	range.TextSize = 12
	range.TextColor3 = Color3.fromRGB(255, 226, 140)
	range.TextStrokeTransparency = 0.4
	range.Parent = ring
	-- The launcher's scope: the edge of the glass, drawn when the view is right down it.
	local scope = Instance.new("Frame")
	scope.Name = "Scope"
	scope.AnchorPoint = Vector2.new(0.5, 0.5)
	scope.Position = UDim2.fromScale(0.5, 0.5)
	scope.Size = UDim2.fromScale(0.62, 0.62)
	scope.SizeConstraint = Enum.SizeConstraint.RelativeYY
	scope.BackgroundTransparency = 1
	scope.Visible = false
	scope.Parent = gui
	Instance.new("UICorner", scope).CornerRadius = UDim.new(1, 0)
	local scopeEdge = Instance.new("UIStroke")
	scopeEdge.Thickness = 10
	scopeEdge.Color = Color3.fromRGB(12, 12, 14)
	scopeEdge.Parent = scope
	for index, spec in ipairs({ { 0.5, 0.5, 0.004, 0.7 }, { 0.5, 0.5, 0.7, 0.004 } }) do
		local line = Instance.new("Frame")
		line.Name = "Hair" .. index
		line.AnchorPoint = Vector2.new(0.5, 0.5)
		line.Position = UDim2.fromScale(spec[1], spec[2])
		line.Size = UDim2.fromScale(spec[3], spec[4])
		line.BackgroundColor3 = Color3.fromRGB(20, 20, 22)
		line.BackgroundTransparency = 0.2
		line.BorderSizePixel = 0
		line.Parent = scope
	end
	return gui, { cross = cross, ring = ring, stroke = stroke, dot = dot, range = range, scope = scope }
end

-- Starts the view on `vehicle`'s turret, or returns nil if the model carries no first-person markers
-- (a stand-in in a harness, a registered kind): VehicleWeaponClient then keeps its plain aim.
-- options: character (for the arms; default the local player's), noInput (a gallery poses it by hand),
-- guiParent (where the sight goes; default the local player's PlayerGui -- a gallery has no player).
function GunnerView.Start(vehicle, spec, options)
	options = options or {}
	local names = VehicleWeaponData.Parts.turret
	local yawPart, pitchPart, muzzle = vehicle:FindFirstChild(names.yaw), vehicle:FindFirstChild(names.pitch), vehicle:FindFirstChild(names.muzzle)
	local yawJoint, pitchJoint = jointOf(yawPart), jointOf(pitchPart)
	local eye = yawPart and yawPart:FindFirstChild("GunnerEye")
	-- A stationary emplacement (MountedGuns) carries its GunnerEye on TurretPitch instead: the gunner's head
	-- rides the grips up and down, so the hip view always looks through the shield's sight window.
	local eyeOnPitch = false
	if not eye and pitchPart and pitchPart:FindFirstChild("GunnerEye") then
		eye, eyeOnPitch = pitchPart:FindFirstChild("GunnerEye"), true
	end
	local sight = pitchPart and pitchPart:FindFirstChild("GunnerSight")
	local gripR, gripL = pitchPart and pitchPart:FindFirstChild("GripR"), pitchPart and pitchPart:FindFirstChild("GripL")
	if not (yawJoint and pitchJoint and muzzle and eye and sight and gripR and gripL and yawJoint.Part0) then
		return nil
	end
	local self = setmetatable({}, GunnerView)
	self.vehicle = vehicle
	self.spec = spec
	self.yawPart, self.pitchPart, self.muzzle = yawPart, pitchPart, muzzle
	self.yawJoint, self.pitchJoint = yawJoint, pitchJoint
	self.eye, self.sight, self.gripR, self.gripL = eye, sight, gripR, gripL
	self.eyeOnPitch = eyeOnPitch
	self.reloadHand = (yawPart:FindFirstChild("ReloadHand") or pitchPart:FindFirstChild("ReloadHand"))
	self.reloadOnYaw = yawPart:FindFirstChild("ReloadHand") ~= nil
	-- The mount's shape at rest, in the yaw pivot's own frame (what VehicleWeaponData.Solve takes).
	-- Read off the joints and the pitch pivot's own frame, not the parts' places: the turret may be
	-- swung already (everyone's mounts follow their attributes).
	self.pivot = pitchJoint.C0.Position
	self.mouth = pitchPart.CFrame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
	self.lobs = Pure.lobs(spec)
	self.sightKind = Pure.sightKind(spec)
	-- A scope is a solid tube: looked through, its own parts (named *Sight*: the body, the lens, the eye
	-- cup, the bracket) are hidden on this screen, or the view down it is the inside of a box.
	self.scopeParts = {}
	if self.sightKind == "scope" then
		for _, part in ipairs(vehicle:GetChildren()) do
			if part:IsA("BasePart") and string.find(part.Name, "Sight") then
				table.insert(self.scopeParts, part)
			end
		end
	end
	self.kick = Pure.kickOf(spec)
	self.round = spec.kind == "round" and Ballistics.Rounds[spec.projectile] or nil
	self.yaw, self.pitch = 0, spec.restPitch or 0
	self.wantYaw, self.wantPitch = self.yaw, self.pitch
	self.viewPitch = -8
	self.aim = 0
	self.aiming = false
	self.kickPitch, self.kickPitchV, self.kickBack, self.kickBackV = 0, 0, 0, 0
	self.shake = 0
	self.reload = 0
	self.stick = Vector2.zero
	self.touch = Vector2.zero
	self.noInput = options.noInput == true
	self.params = sightParams(vehicle)
	self.settings = settings()
	local camera = workspace.CurrentCamera
	self.camera = camera
	self.savedFov = camera.FieldOfView
	self.savedType = camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable
	-- The avatar's own arms (Viewmodel.Arms); stand-in blocks if the avatar has none.
	local Viewmodel = require(script.Parent:WaitForChild("Viewmodel"))
	local character = options.character or (player and player.Character)
	local container = Instance.new("Model")
	container.Name = "GunnerArms"
	local ok, arms = pcall(Viewmodel.Arms.new, container, character)
	if not ok then
		arms = Viewmodel.Arms.new(container, nil)
	end
	self.arms = arms
	self.armsModel = container
	container.Parent = camera
	self.character = character
	self.gui, self.ui = makeGui(options.guiParent)
	if player then
		player:SetAttribute("GunnerView", true)
	end
	self:hideBody(true)
	if not self.noInput then
		self.connections = {
			UserInputService.InputChanged:Connect(function(input, processed)
				if input.KeyCode == Enum.KeyCode.Thumbstick2 then
					local stick = input.Position
					self.stick = stick.Magnitude > 0.15 and Vector2.new(stick.X, stick.Y) or Vector2.zero
				elseif input.UserInputType == Enum.UserInputType.Touch and not processed then
					self.touch += Vector2.new(input.Delta.X, input.Delta.Y)
				end
			end),
		}
	end
	return self
end

-- The body out of the way of the camera (the arms are the viewmodel's), shown again after.
function GunnerView:hideBody(hide)
	local character = self.character
	if not character then
		return
	end
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("Decal") then
			part.LocalTransparencyModifier = hide and 1 or 0
		end
	end
end

function GunnerView:SetAiming(on)
	self.aiming = on == true
end

-- The look this frame from the mouse, the stick and a touch drag, held to the arc.
function GunnerView:look(dt)
	if self.noInput then
		return
	end
	local fovShare = 1 - self.aim * (1 - (Pure.Zoom[self.sightKind] or 0.6))
	local aimSens = self.settings and tonumber(self.settings.Get("AimSensitivity")) or 0.7
	local scale = fovShare * (1 - self.aim + self.aim * aimSens)
	local menu = player ~= nil and player:GetAttribute("MenuOpen") == true
	if not menu then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		local delta = UserInputService:GetMouseDelta()
		self.wantYaw -= delta.X * Pure.MouseDegrees * scale
		self.wantPitch -= delta.Y * Pure.MouseDegrees * scale
	end
	-- The stick on a curve (fine near the middle, full speed at the edge) and a ramp that builds while it is
	-- held over, so a small correction is precise and a long swing still gets there.
	local held = self.stick.Magnitude > 0.85
	self.stickHeld = held and math.min(1, (self.stickHeld or 0) + dt / Pure.StickRampTime) or 0
	local boost = 1 + (Pure.StickRamp - 1) * self.stickHeld
	self.wantYaw -= Pure.stickCurve(self.stick.X) * Pure.StickDegrees * boost * scale * dt
	self.wantPitch += Pure.stickCurve(self.stick.Y) * Pure.StickDegrees * boost * scale * dt
	self.wantYaw -= self.touch.X * Pure.TouchDegrees * scale
	self.wantPitch -= self.touch.Y * Pure.TouchDegrees * scale
	self.touch = Vector2.zero
	self.wantYaw, self.wantPitch = Pure.clampLook(self.spec, self.wantYaw, self.wantPitch)
end

-- The yaw pivot's frame at rest (the chassis moves; the frame follows it) and as turned now.
function GunnerView:frames()
	local rest = self.yawJoint.Part0.CFrame * self.yawJoint.C0
	local yawFrame = rest * CFrame.Angles(0, math.rad(self.yaw), 0)
	local pitchFrame = yawFrame * self.pitchJoint.C0 * CFrame.Angles(math.rad(self.pitch + self.kickPitch), 0, 0)
		* CFrame.new(0, 0, self.kickBack)
	return rest, yawFrame, pitchFrame
end

function GunnerView:AimPoint()
	local rest = self.yawJoint.Part0.CFrame * self.yawJoint.C0
	local origin, direction = Pure.barrel(rest, self.pivot, self.mouth, self.yaw, self.pitch)
	return origin + direction * 1000, origin, direction
end

function GunnerView:Fired()
	self.kickPitchV += self.kick.pitch * 60
	self.kickBackV += self.kick.back * 60
	self.shake = math.min(1.5, self.shake + self.kick.shake)
end

-- One frame. `state` = { ready = bool } from VehicleWeaponClient (the mount's ammo and heat).
function GunnerView:Update(dt, state)
	if not self.vehicle.Parent or not self.yawJoint.Part0 then
		return
	end
	dt = math.min(dt, 0.1)
	self:look(dt)
	-- Damped, speed- and acceleration-limited (Pure.follow); `slewAccel` defaults to six times the slew.
	local speed = self.spec.slew or 240
	local accel = self.spec.slewAccel or speed * 6
	self.yaw, self.yawV = Pure.follow(self.yaw, self.yawV or 0, self.wantYaw, dt, speed, accel, self.spec.yawLimit >= 180)
	self.pitch, self.pitchV = Pure.follow(self.pitch, self.pitchV or 0, self.wantPitch, dt, speed, accel, false)
	-- The kick springs back, sub-stepped.
	local left = dt
	while left > 1e-4 do
		local h = math.min(left, 1 / 120)
		self.kickPitch, self.kickPitchV = Pure.spring(self.kickPitch, self.kickPitchV, h, 220, 22)
		self.kickBack, self.kickBackV = Pure.spring(self.kickBack, self.kickBackV, h, 260, 26)
		left -= h
	end
	self.shake = math.max(0, self.shake - dt * 4)
	self.aim += ((self.aiming and 1 or 0) - self.aim) * math.min(1, dt * 12)
	-- The local turret, kick and all (VehicleWeaponClient leaves this one alone while the view runs).
	self.yawJoint.Transform = CFrame.Angles(0, math.rad(self.yaw), 0)
	self.pitchJoint.Transform = CFrame.Angles(math.rad(self.pitch + self.kickPitch), 0, 0) * CFrame.new(0, 0, self.kickBack)

	local rest, yawFrame, pitchFrame = self:frames()
	-- Where the shot will land, from the barrel as it is (no kick: the server fires the barrel's line).
	local origin, direction = Pure.barrel(rest, self.pivot, self.mouth, self.yaw, self.pitch)
	local params = self.params
	local impact, hit = Pure.impact(self.spec, self.round, origin, direction, workspace.Gravity, function(from, to)
		local result = workspace:Raycast(from, to - from, params)
		return result and result.Position or nil
	end)
	self.impact, self.impactHit = impact, hit

	-- The camera: the eye, turned with the yaw and tipped with the barrel (or, lobbing, toward where the
	-- bomb comes down); aiming, at the sight.
	local hipEye = (self.eyeOnPitch and pitchFrame or yawFrame) * self.eye.CFrame
	local lookPitch = self.pitch + self.kickPitch
	if self.lobs then
		local flat = Vector3.new(impact.X - hipEye.X, 0, impact.Z - hipEye.Z).Magnitude
		local want = math.clamp(math.deg(math.atan2(impact.Y - hipEye.Y, math.max(flat, 1))), -40, 12)
		self.viewPitch += (want - self.viewPitch) * math.min(1, dt * 6)
		lookPitch = self.viewPitch
	end
	local hipView = CFrame.new(hipEye.Position) * (yawFrame - yawFrame.Position) * CFrame.Angles(math.rad(lookPitch), 0, 0)
	local sightView = pitchFrame * self.sight.CFrame
	if self.lobs then
		-- A mortar is laid by where its bomb comes down, not along its tube: aiming only zooms the view
		-- (from beside the tube, the sight's own spot, the van's roof load filled the picture).
		sightView = hipView
	end
	local view = hipView:Lerp(sightView, Pure.smooth(self.aim))
	if self.shake > 0 then
		local s = self.shake
		view = view * CFrame.Angles(math.rad((math.random() - 0.5) * s), math.rad((math.random() - 0.5) * s), math.rad((math.random() - 0.5) * s * 0.6))
	end
	local camera = self.camera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = view
	local baseFov = self.settings and tonumber(self.settings.Get("FieldOfView")) or self.savedFov or 70
	camera.FieldOfView = baseFov * (1 - Pure.smooth(self.aim) * (1 - (Pure.Zoom[self.sightKind] or 0.6)))

	-- The hands: on the grips, the right one off to load while the mount isn't ready.
	local ready = state == nil or state.ready ~= false
	self.reload = ready and math.max(0, self.reload - dt * 2.5) or (self.reload + dt / 1.2)
	local right = pitchFrame * self.gripR.CFrame
	local left = pitchFrame * self.gripL.CFrame
	if not ready or self.reload > 0 then
		local phase = ready and 0 or (self.reload % 1)
		local out = Pure.smooth(math.min(1, phase * 3)) * (1 - Pure.smooth(math.max(0, phase * 3 - 2)))
		if ready then
			out = self.reload
		end
		local loadFrame = self.reloadHand and ((self.reloadOnYaw and yawFrame or pitchFrame) * self.reloadHand.CFrame) or right * CFrame.new(0, 0.3, 0.4)
		right = right:Lerp(loadFrame, math.clamp(out, 0, 1))
	end
	local parts, cframes = {}, {}
	self.arms:pose(1, view, right, 0.9, parts, cframes)
	self.arms:pose(-1, view, left, 0.9, parts, cframes)
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	-- The scope's glass only when the view is right down the launcher's sight.
	local scoped = self.sightKind == "scope" and self.aim > 0.9
	self.arms:SetHidden(scoped)
	if scoped ~= self.scopeHidden then
		self.scopeHidden = scoped
		for _, part in ipairs(self.scopeParts) do
			part.LocalTransparencyModifier = scoped and 1 or 0
		end
	end
	self.ui.scope.Visible = scoped
	self:placeSight(view, impact, hit)
	self:hideBody(true)
end

function GunnerView:placeSight(view, impact, hit)
	local camera = self.camera
	local screen, onScreen = camera:WorldToViewportPoint(impact)
	local ui = self.ui
	ui.ring.Visible = onScreen
	if onScreen then
		ui.ring.Position = UDim2.fromOffset(screen.X, screen.Y)
	end
	local color = hit and Color3.fromRGB(255, 214, 90) or Color3.fromRGB(170, 174, 184)
	ui.stroke.Color = color
	ui.dot.BackgroundColor3 = color
	local distance = (impact - view.Position).Magnitude
	ui.range.Text = self.spec.kind == "round" and string.format("%d", math.floor(distance + 0.5)) or ""
	ui.cross.Visible = not self.lobs
end

function GunnerView:Stop()
	if self.stopped then
		return
	end
	self.stopped = true
	for _, connection in ipairs(self.connections or {}) do
		connection:Disconnect()
	end
	if self.armsModel then
		self.armsModel:Destroy()
	end
	if self.gui then
		self.gui:Destroy()
	end
	self:hideBody(false)
	for _, part in ipairs(self.scopeParts or {}) do
		part.LocalTransparencyModifier = 0
	end
	if player then
		player:SetAttribute("GunnerView", nil)
	end
	local camera = self.camera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = self.settings and tonumber(self.settings.Get("FieldOfView")) or self.savedFov or 70
	local humanoid = player and player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	if not self.noInput then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end

return GunnerView
