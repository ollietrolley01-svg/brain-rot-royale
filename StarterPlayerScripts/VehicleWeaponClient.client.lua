-- Mounted vehicle weapons on the client: the driver's trigger and aim, the ammo readout, and every
-- armed vehicle's turret swinging to where its driver is looking.
--
-- The server decides everything that matters (VehicleWeapons): this only says where the driver is
-- aiming and when they pull the trigger. The shot itself comes back through ShotFired (tracer,
-- report) and ProjectileService's round events like any gun's.
--
-- Controls while driving an armed vehicle: the fire button (left mouse, R1 on a gamepad, since the
-- triggers are the throttle and brake, or the FIRE touch button this binds) fires the mount along the
-- camera. CombatClient refuses the hand gun from the driving seat, so the two never both fire.
--
-- The turret swings on its two Motor6Ds' Transform (VehicleModels, Mounted weapons): from the
-- server's AimYaw/AimPitch for everyone else's, from the driver's own camera for their own, so it
-- answers the mouse the moment it moves.

local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local fireRemote = Remotes.Event("VehicleWeaponFire")
local aimRemote = Remotes.Event("VehicleWeaponAim")

local AIM_SEND_EVERY = 0.1
local AIM_RANGE = 1000
-- Degrees a second the turret swings at most when following someone else's aim, so a 10 Hz
-- attribute reads as a turret turning rather than one jumping.
local SWING_RATE = 240
local TAG = "ArmedVehicle"

--------------------------------------------------------------------------------
-- HUD
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "VehicleWeaponHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

-- Right of the vehicle panel (VehicleClient: 250 wide, centred, 178 up), same height and style.
local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0, 1)
panel.Position = UDim2.new(0.5, 133, 1, -178)
panel.Size = UDim2.fromOffset(150, 78)
panel.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
panel.BackgroundTransparency = 0.25
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local nameLabel = Instance.new("TextLabel")
nameLabel.BackgroundTransparency = 1
nameLabel.Position = UDim2.fromOffset(12, 6)
nameLabel.Size = UDim2.new(1, -24, 0, 14)
nameLabel.Font = Enum.Font.GothamBold
nameLabel.TextSize = 12
nameLabel.TextXAlignment = Enum.TextXAlignment.Left
nameLabel.TextColor3 = Color3.fromRGB(170, 176, 190)
nameLabel.Parent = panel

local ammoLabel = Instance.new("TextLabel")
ammoLabel.BackgroundTransparency = 1
ammoLabel.Position = UDim2.fromOffset(12, 20)
ammoLabel.Size = UDim2.new(1, -24, 0, 32)
ammoLabel.Font = Enum.Font.FredokaOne
ammoLabel.TextSize = 28
ammoLabel.TextXAlignment = Enum.TextXAlignment.Left
ammoLabel.TextColor3 = Color3.fromRGB(245, 245, 250)
ammoLabel.Parent = panel

local barBack = Instance.new("Frame")
barBack.Position = UDim2.new(0, 12, 1, -16)
barBack.Size = UDim2.new(1, -24, 0, 6)
barBack.BackgroundColor3 = Color3.fromRGB(50, 54, 64)
barBack.BorderSizePixel = 0
barBack.Parent = panel
Instance.new("UICorner", barBack).CornerRadius = UDim.new(1, 0)

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(1, 1)
barFill.BackgroundColor3 = Color3.fromRGB(255, 196, 64)
barFill.BorderSizePixel = 0
barFill.Parent = barBack
Instance.new("UICorner", barFill).CornerRadius = UDim.new(1, 0)

-- The combat crosshair stands down while you drive; the mount fires along the middle of the view.
local reticle = Instance.new("Frame")
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(8, 8)
reticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
reticle.BackgroundTransparency = 0.15
reticle.BorderSizePixel = 0
reticle.Parent = gui
Instance.new("UICorner", reticle).CornerRadius = UDim.new(1, 0)
local reticleRing = Instance.new("UIStroke")
reticleRing.Color = Color3.fromRGB(20, 20, 24)
reticleRing.Thickness = 1.5
reticleRing.Parent = reticle

--------------------------------------------------------------------------------
-- Driving and aiming
--------------------------------------------------------------------------------

-- The armed vehicle this player is driving, with its spec, or nil.
local function drivenVehicle()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat or not seat:IsA("VehicleSeat") then
		return nil
	end
	local vehicle = seat.Parent
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"))
	if not spec or not vehicle:FindFirstChild("TurretYaw") then
		return nil
	end
	return vehicle, spec
end

-- What's under the middle of the view, past the vehicle and everyone in it.
local function aimPoint(vehicle)
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	local filter = { vehicle }
	if player.Character then
		table.insert(filter, player.Character)
	end
	for _, name in ipairs({ "Loot", "Effects" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	-- As the server's bullet: water doesn't stop it (CombatService.buildRaycastParams).
	params.IgnoreWater = true
	local result = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, params)
	return result and result.Position or ray.Origin + ray.Direction * AIM_RANGE
end

local firing = false
local lastShotAt = 0
local lastAimAt = 0

local function onFire(_, inputState, inputObject)
	if not drivenVehicle() then
		firing = false
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		firing = true
	elseif inputState == Enum.UserInputState.End then
		firing = false
	end
	-- The mouse button also belongs to the camera and CombatClient (which passes it on while you
	-- drive); R1 would otherwise cycle the hotbar under you.
	if inputObject and inputObject.KeyCode == Enum.KeyCode.ButtonR1 then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local bound = false
local function setBound(want)
	if want == bound then
		return
	end
	bound = want
	if want then
		ContextActionService:BindAction("BRR_VehicleFire", onFire, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR1)
		ContextActionService:SetTitle("BRR_VehicleFire", "FIRE")
		ContextActionService:SetPosition("BRR_VehicleFire", UDim2.new(1, -140, 1, -180))
	else
		ContextActionService:UnbindAction("BRR_VehicleFire")
		firing = false
	end
end

--------------------------------------------------------------------------------
-- Turrets
--------------------------------------------------------------------------------

-- Current swing per vehicle, in degrees. STRONG keys, dropped when the vehicle leaves.
local swings = {}

local function jointOf(vehicle, name)
	local pivot = vehicle:FindFirstChild(name)
	local joint = pivot and pivot:FindFirstChild("Joint")
	return joint and joint:IsA("Motor6D") and joint or nil
end

local function approach(from, to, step)
	if math.abs(to - from) <= step then
		return to
	end
	return from + math.sign(to - from) * step
end

local function swingTurret(vehicle, spec, yawTarget, pitchTarget, dt)
	local yawJoint, pitchJoint = jointOf(vehicle, "TurretYaw"), jointOf(vehicle, "TurretPitch")
	if not yawJoint or not pitchJoint then
		return
	end
	local swing = swings[vehicle]
	if not swing then
		swing = { yaw = 0, pitch = spec.restPitch or 0 }
		swings[vehicle] = swing
	end
	local step = SWING_RATE * dt
	swing.yaw = approach(swing.yaw, yawTarget, step)
	swing.pitch = approach(swing.pitch, pitchTarget, step)
	yawJoint.Transform = CFrame.Angles(0, math.rad(swing.yaw), 0)
	pitchJoint.Transform = CFrame.Angles(math.rad(swing.pitch), 0, 0)
end

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(vehicle)
	swings[vehicle] = nil
end)

--------------------------------------------------------------------------------
-- Loop
--------------------------------------------------------------------------------

RunService.RenderStepped:Connect(function(dt)
	local mine, spec = drivenVehicle()
	setBound(mine ~= nil)
	gui.Enabled = mine ~= nil

	local now = workspace:GetServerTimeNow()
	if mine then
		local target = aimPoint(mine)
		-- The driver's own turret follows their camera straight away, by the server's own limits.
		local yawPart, pitchPart = mine:FindFirstChild("TurretYaw"), mine:FindFirstChild("TurretPitch")
		if yawPart and pitchPart then
			local joint = yawPart:FindFirstChild("Joint")
			-- The unswung mount frame: the yaw pivot's rest frame from its joint's parent.
			local rest = joint and joint.Part0 and joint.Part0.CFrame * joint.C0 or yawPart.CFrame
			local yaw, pitch = VehicleWeaponData.ClampAim(spec, rest:VectorToObjectSpace(target - pitchPart.Position))
			swingTurret(mine, spec, math.deg(yaw), math.deg(pitch), dt * 3)
		end

		if firing and now - lastShotAt >= 1 / spec.fireRate then
			lastShotAt = now
			lastAimAt = now -- the server takes the aim from the shot too
			fireRemote:FireServer(target)
		elseif now - lastAimAt >= AIM_SEND_EVERY then
			lastAimAt = now
			aimRemote:FireServer(target)
		end

		local ammo = VehicleWeaponData.AmmoAt(spec, mine:GetAttribute("WeaponAmmo") or spec.magazine,
			mine:GetAttribute("WeaponFiredAt"), now)
		local whole = math.floor(ammo)
		nameLabel.Text = spec.hud
		ammoLabel.Text = string.format("%d / %d", whole, spec.magazine)
		ammoLabel.TextColor3 = whole < 1 and Color3.fromRGB(255, 96, 96) or Color3.fromRGB(245, 245, 250)
		barFill.Size = UDim2.fromScale(math.clamp(ammo / spec.magazine, 0, 1), 1)
	end

	-- Everyone else's turrets, from what their drivers last sent; an empty one settles to rest.
	local eye = camera.CFrame.Position
	for _, vehicle in ipairs(CollectionService:GetTagged(TAG)) do
		if vehicle ~= mine and vehicle.PrimaryPart and (vehicle.PrimaryPart.Position - eye).Magnitude < 400 then
			local other = VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"))
			if other then
				local seat = vehicle:FindFirstChild("DriverSeat")
				local manned = seat and seat:IsA("VehicleSeat") and seat.Occupant ~= nil
				local yaw = manned and vehicle:GetAttribute("AimYaw") or 0
				local pitch = manned and vehicle:GetAttribute("AimPitch") or other.restPitch or 0
				swingTurret(vehicle, other, yaw, pitch, dt)
			end
		end
	end
end)
