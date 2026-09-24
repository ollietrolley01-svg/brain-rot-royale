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
local UserInputService = game:GetService("UserInputService")

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
-- Aiming at the mouse (Oliver: "the aim to follow your mouse")
--------------------------------------------------------------------------------

-- With a mouse, the gun aims along the ray through the cursor, not the middle of the screen: the
-- turret follows the mouse, the aim mark is drawn at the cursor (the OS arrow is hidden while it is)
-- and the shot goes through that point. Outside the mount's arc the mark stops at the arc's edge and
-- greys, and the shot goes along that edge (the server clamps to the same arc). A pad and a touch
-- screen keep the middle, and so does a mouse locked to the middle (first person, shift-lock), where
-- the cursor IS the middle. tools/vehicle_aim_check.py runs the block marked PURE on its own.

-- PURE BEGIN (plain Lua, no Roblox types)
local MOUSE_INPUTS = {
	MouseMovement = true, MouseButton1 = true, MouseButton2 = true, MouseButton3 = true, MouseWheel = true,
	Keyboard = true,
}

-- "mouse" when the player is on a mouse and it is free to move, else "centre".
local function aimMode(lastInputName, mouseLocked)
	if MOUSE_INPUTS[lastInputName] and not mouseLocked then
		return "mouse"
	end
	return "centre"
end

-- The screen point (viewport pixels, the frame GetMouseLocation and ViewportPointToRay share) the gun
-- aims through: the cursor, held on the screen, or the middle.
local function aimScreenPoint(mode, mouseX, mouseY, width, height)
	if mode == "mouse" then
		return math.clamp(mouseX, 0, width), math.clamp(mouseY, 0, height)
	end
	return width / 2, height / 2
end

-- The mount-space direction (front -Z, up +Y) for a yaw and pitch: the inverse of
-- VehicleWeaponData.ClampAim's two angles.
local function directionFromAngles(yaw, pitch)
	return -math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)
end

-- Whether the aim was held back by the arc: the clamped angles differ from the wanted ones.
local function pinnedToArc(wantYaw, wantPitch, yaw, pitch)
	return math.abs(wantYaw - yaw) > 1e-4 or math.abs(wantPitch - pitch) > 1e-4
end
-- PURE END

local function aimScreen()
	local viewport = camera.ViewportSize
	local locked = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
	local mode = aimMode(UserInputService:GetLastInputType().Name, locked)
	local mouse = UserInputService:GetMouseLocation()
	local x, y = aimScreenPoint(mode, mouse.X, mouse.Y, viewport.X, viewport.Y)
	return x, y, mode
end

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
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

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

-- The gun's one aim mark (HudClient's crosshair stands down while VehicleGunActive): at the cursor with
-- a mouse, in the middle otherwise, grey and held at the arc's edge when the aim is outside it.
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

-- The gunner's seat of an armed vehicle, if it has one: a Seat named "GunnerSeat", or any seat with a
-- true "Gunner" attribute (being added to armed vehicles alongside this).
local function gunnerSeatOf(vehicle)
	for _, child in ipairs(vehicle:GetChildren()) do
		if child:IsA("Seat") and (child.Name == "GunnerSeat" or child:GetAttribute("Gunner") == true) then
			return child
		end
	end
	return nil
end

-- The armed vehicle whose gun this player works, with its spec, or nil: whoever sits in the gunner's
-- seat, and the driver while that seat is empty (or there is none), so a player alone in an armed
-- vehicle can still fire it. The same rule as the server's VehicleWeapons.DrivenBy. The name is kept
-- from when only the driver could fire.
local function drivenVehicle()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return nil
	end
	local vehicle = seat.Parent
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"))
	if not spec or not vehicle:FindFirstChild("TurretYaw") then
		return nil
	end
	local gunner = gunnerSeatOf(vehicle)
	if seat ~= gunner then
		if not seat:IsA("VehicleSeat") or (gunner ~= nil and gunner.Occupant ~= nil) then
			return nil
		end
	end
	return vehicle, spec
end

-- What's under the middle of the view, past the vehicle and everyone in it.
local function aimPoint(vehicle, screenX, screenY)
	local ray = camera:ViewportPointToRay(screenX, screenY)
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
	-- drive); R1 would otherwise cycle the hotbar under you. A gunner is a passenger to CombatClient,
	-- which would fire the gun in their hands as well, so a gunner's click stops here.
	if inputObject and inputObject.KeyCode == Enum.KeyCode.ButtonR1 then
		return Enum.ContextActionResult.Sink
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart and not humanoid.SeatPart:IsA("VehicleSeat") then
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
	-- Said on the player, locally, for the rest of the HUD: HudClient stands its own crosshair down
	-- (one crosshair while the vehicle gun is yours, this one) and hides the stamina bar, and BoonHud
	-- steps out of the phone's driving block, for a gunner as for a driver.
	player:SetAttribute("VehicleGunActive", want or nil)
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

-- On a touch screen, PhoneLayout's slot for it (`Rects().vehicleGun`, in the driving block beside or
-- under VehicleClient's speed panel). Worked out when the screen changes, not every frame; nil on a
-- desktop screen or if PhoneLayout is missing.
local phoneGunSpot = nil
do
	local ok, PhoneLayout = pcall(require, script.Parent:WaitForChild("PhoneLayout", 5))
	local function refit()
		local viewport = camera.ViewportSize
		phoneGunSpot = ok and type(PhoneLayout) == "table" and PhoneLayout.Active(viewport) and PhoneLayout.Rects(viewport).vehicleGun or nil
	end
	refit()
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	game:GetService("UserInputService"):GetPropertyChangedSignal("KeyboardEnabled"):Connect(refit)
end

-- Otherwise the desktop spot, right of VehicleClient's speed panel (250 wide, centred, 178 up) with its
-- bottom level: the driving block's own numbers, not a measurement of the panel. Measuring it read the
-- panel's box on the frame driving began, before VehicleClient had enabled or placed its HUD, and a
-- gunner has no speed panel at all (#80, Oliver: "the guns on the cars HUD is overlapping").
local function followVehiclePanel()
	local k, anchor, position
	if phoneGunSpot then
		k, anchor, position = phoneGunSpot.w / 150, Vector2.new(0, 0), UDim2.fromOffset(phoneGunSpot.x, phoneGunSpot.y)
	else
		k, anchor, position = 1, Vector2.new(0, 1), UDim2.new(0.5, 133, 1, -178)
	end
	if panelScale.Scale ~= k then
		panelScale.Scale = k
	end
	if panel.AnchorPoint ~= anchor or panel.Position ~= position then
		panel.AnchorPoint = anchor
		panel.Position = position
	end
end

local reticleAt = nil
local function placeReticle(x, y, pinned)
	local key = string.format("%.1f %.1f %s", x, y, tostring(pinned))
	if key == reticleAt then
		return
	end
	reticleAt = key
	reticle.Position = UDim2.fromOffset(x, y)
	reticle.BackgroundColor3 = pinned and Color3.fromRGB(150, 154, 164) or Color3.fromRGB(255, 255, 255)
	reticle.BackgroundTransparency = pinned and 0.4 or 0.15
end

-- The OS arrow is hidden while the aim mark is the cursor, and given back when it is not (a menu, a
-- pad, leaving the seat). MenuCursor is the one script that writes MouseIconEnabled (#112), so this
-- only says so, through the player's `AimCursor` attribute (local: a client's attribute on its own
-- Player never leaves this machine), and MenuCursor hides the arrow while it is set. Writing the
-- property here fought MenuCursor: its reconcile on every MouseBehavior change (a right-drag of the
-- camera) put the arrow back beside the mark, and this script's "give it back" on leaving the seat
-- set it visible in first-person combat -- #112's "can still see my cursor in FPS" again.
local hidCursor = false
local function setCursorHidden(hide)
	if hide == hidCursor then
		return
	end
	hidCursor = hide
	player:SetAttribute("AimCursor", hide or nil)
end

RunService.RenderStepped:Connect(function(dt)
	local mine, spec = drivenVehicle()
	setBound(mine ~= nil)
	gui.Enabled = mine ~= nil
	if mine then
		followVehiclePanel()
	else
		setCursorHidden(false)
	end

	local now = workspace:GetServerTimeNow()
	if mine then
		local screenX, screenY, mode = aimScreen()
		setCursorHidden(mode == "mouse" and player:GetAttribute("MenuOpen") ~= true)
		local target = aimPoint(mine, screenX, screenY)
		placeReticle(screenX, screenY, false)
		-- The turret follows the aim straight away, by the server's own limits.
		local yawPart, pitchPart = mine:FindFirstChild("TurretYaw"), mine:FindFirstChild("TurretPitch")
		if yawPart and pitchPart then
			local joint = yawPart:FindFirstChild("Joint")
			-- The unswung mount frame: the yaw pivot's rest frame from its joint's parent.
			local rest = joint and joint.Part0 and joint.Part0.CFrame * joint.C0 or yawPart.CFrame
			local toTarget = target - pitchPart.Position
			local direction = rest:VectorToObjectSpace(toTarget)
			local yaw, pitch = VehicleWeaponData.ClampAim(spec, direction)
			swingTurret(mine, spec, math.deg(yaw), math.deg(pitch), dt * 3)
			local wantYaw = math.atan2(-direction.X, -direction.Z)
			local wantPitch = math.atan2(direction.Y, math.sqrt(direction.X * direction.X + direction.Z * direction.Z))
			if pinnedToArc(wantYaw, wantPitch, yaw, pitch) then
				-- The mark goes where the gun can point: along the arc's edge, as far out as the aim.
				local dx, dy, dz = directionFromAngles(yaw, pitch)
				local edge = pitchPart.Position + rest:VectorToWorldSpace(Vector3.new(dx, dy, dz)) * toTarget.Magnitude
				local screen, onScreen = camera:WorldToViewportPoint(edge)
				if onScreen then
					placeReticle(screen.X, screen.Y, true)
				else
					placeReticle(screenX, screenY, true)
				end
			end
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
				local gunner = gunnerSeatOf(vehicle)
				local manned = (seat and seat:IsA("VehicleSeat") and seat.Occupant ~= nil) or (gunner ~= nil and gunner.Occupant ~= nil)
				local yaw = manned and vehicle:GetAttribute("AimYaw") or 0
				local pitch = manned and vehicle:GetAttribute("AimPitch") or other.restPitch or 0
				swingTurret(vehicle, other, yaw, pitch, dt)
			end
		end
	end
end)
