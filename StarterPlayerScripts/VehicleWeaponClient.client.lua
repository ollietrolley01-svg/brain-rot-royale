-- Mounted vehicle weapons on the client: the trigger and aim of whichever mount this player works,
-- the ammo and heat readout, the gunner's first-person view, and every armed vehicle's mounts
-- swinging to where their users are aiming.
--
-- The server decides everything that matters (VehicleWeapons): this only says where the mount is
-- aiming and when the trigger is pulled. The shot itself comes back through ShotFired (tracer,
-- report) and ProjectileService's round events like any gun's.
--
-- WHO WORKS WHAT (VehicleWeapons, the same rule): the gunner's seat works the TURRET, the driving seat
-- works the DRIVER'S GUN (a short-arc gun at the front). A driver alone cannot work the turret.
--
-- The DRIVER aims with the mouse while driving (the gun follows the cursor, inside its 20-degree arc,
-- Oliver: "the aim to follow your mouse") or the camera's middle on a pad or a touch screen, and fires
-- with the left mouse, R1 (the triggers are the throttle and brake) or the FIRE button.
-- The GUNNER sees down the gun (GunnerView: the camera at their eye riding the turret, their own arms
-- on its handles, a sight that shows where the shot lands): the mouse, the right stick or a drag turns
-- the turret; the left mouse, R2 or R1, or FIRE fires; the right mouse, L2 or the AIM button aims down
-- the sight. On a model with no first-person markers the gunner gets the driver's kind of aim instead.
-- CombatClient refuses the hand gun from the driving seat, and this sinks a gunner's fire and aim
-- buttons before CombatClient sees them, so a hand gun never fires or aims alongside a mount.
--
-- The mounts swing on their two Motor6Ds' Transform (VehicleModels, Mounted weapons): from the
-- server's aim attributes for everyone else's, from this player's own aim for theirs, so it answers
-- the mouse the moment it moves.

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
-- Degrees a second a mount swings at most when following someone else's aim, so a 10 Hz
-- attribute reads as a turret turning rather than one jumping.
local SWING_RATE = 240
local TAG = "ArmedVehicle"

-- The first-person view (a ModuleScript beside this one). Under pcall: without it, a gunner keeps the
-- plain aim below.
local GunnerView = nil
do
	local ok, module = pcall(function()
		return require(script.Parent:WaitForChild("GunnerView", 5))
	end)
	GunnerView = ok and type(module) == "table" and module or nil
end

--------------------------------------------------------------------------------
-- Aiming at the mouse (Oliver: "the aim to follow your mouse")
--------------------------------------------------------------------------------

-- With a mouse, the gun aims along the ray through the cursor, not the middle of the screen: the
-- mount follows the mouse, the aim mark is drawn at the cursor (the OS arrow is hidden while it is)
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
-- a mouse, in the middle otherwise, grey and held at the arc's edge when the aim is outside it. (In the
-- gunner's first-person view GunnerView draws its own sight and this one is hidden.)
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
-- Which mount is mine
--------------------------------------------------------------------------------

-- The gunner's seat of an armed vehicle, if it has one: a Seat named "GunnerSeat", or any seat with a
-- true "Gunner" attribute.
local function gunnerSeatOf(vehicle)
	for _, child in ipairs(vehicle:GetChildren()) do
		if child:IsA("Seat") and (child.Name == "GunnerSeat" or child:GetAttribute("Gunner") == true) then
			return child
		end
	end
	return nil
end

-- The armed vehicle whose mount this player works, its spec and which mount, or nil: the gunner's seat
-- works the turret and the driving seat the driver's gun -- the server's VehicleWeapons.DrivenBy, the
-- same rule. The name is kept from when only the driver could fire.
local function drivenVehicle()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return nil
	end
	local vehicle = seat.Parent
	local mount
	if seat == gunnerSeatOf(vehicle) then
		mount = "turret"
	elseif seat:IsA("VehicleSeat") then
		mount = "driver"
	else
		return nil
	end
	local spec = vehicle and VehicleWeaponData.ForModel(vehicle:GetAttribute("VehicleModel"), mount)
	if not spec or not vehicle:FindFirstChild(VehicleWeaponData.Parts[mount].yaw) then
		return nil
	end
	return vehicle, spec, mount
end

-- What's under the aim point on the screen, past the vehicle and everyone in it.
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
local view = nil -- the gunner's GunnerView while it runs

local function onFire(_, inputState, inputObject)
	if not drivenVehicle() then
		firing = false
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		firing = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		firing = false
	end
	-- The mouse button also belongs to the camera and CombatClient (which passes it on while you
	-- drive); R1 would otherwise cycle the hotbar under you. A gunner is a passenger to CombatClient,
	-- which would fire the gun in their hands as well, so a gunner's click (and R2) stops here.
	if inputObject and inputObject.KeyCode == Enum.KeyCode.ButtonR1 then
		return Enum.ContextActionResult.Sink
	end
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.SeatPart and not humanoid.SeatPart:IsA("VehicleSeat") then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

-- A gunner's aim-down-the-sight button: held (the right mouse, L2) or toggled (the touch AIM button).
local function onAimSight(_, inputState, inputObject)
	if not view then
		return Enum.ContextActionResult.Pass
	end
	local touch = inputObject and inputObject.UserInputType == Enum.UserInputType.Touch
	if touch then
		if inputState == Enum.UserInputState.Begin then
			view:SetAiming(not view.aiming)
		end
	elseif inputState == Enum.UserInputState.Begin then
		view:SetAiming(true)
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		view:SetAiming(false)
	end
	return Enum.ContextActionResult.Sink
end

local bound = nil -- the mount the fire action is bound for
local function setBound(want)
	if want == bound then
		return
	end
	bound = want
	-- Said on the player, locally, for the rest of the HUD: HudClient stands its own crosshair down
	-- (one crosshair while a vehicle gun is yours, this one) and hides the stamina bar, and BoonHud
	-- steps out of the phone's driving block, for a gunner as for a driver.
	player:SetAttribute("VehicleGunActive", want ~= nil or nil)
	ContextActionService:UnbindAction("BRR_VehicleFire")
	ContextActionService:UnbindAction("BRR_GunnerAim")
	firing = false
	if want == "driver" then
		ContextActionService:BindAction("BRR_VehicleFire", onFire, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR1)
	elseif want == "turret" then
		-- The gunner isn't driving, so the triggers are free: R2 fires as a hand gun does, and L2 aims.
		ContextActionService:BindAction("BRR_VehicleFire", onFire, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2, Enum.KeyCode.ButtonR1)
		ContextActionService:BindAction("BRR_GunnerAim", onAimSight, true, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)
		ContextActionService:SetTitle("BRR_GunnerAim", "AIM")
		ContextActionService:SetPosition("BRR_GunnerAim", UDim2.new(1, -250, 1, -180))
	end
	if want then
		ContextActionService:SetTitle("BRR_VehicleFire", "FIRE")
		ContextActionService:SetPosition("BRR_VehicleFire", UDim2.new(1, -140, 1, -180))
	end
end

--------------------------------------------------------------------------------
-- Mounts
--------------------------------------------------------------------------------

-- Current swing per vehicle and mount, in degrees. STRONG keys, dropped when the vehicle leaves.
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

local function swingMount(vehicle, mount, spec, yawTarget, pitchTarget, dt)
	local names = VehicleWeaponData.Parts[mount]
	local yawJoint, pitchJoint = jointOf(vehicle, names.yaw), jointOf(vehicle, names.pitch)
	if not yawJoint or not pitchJoint then
		return
	end
	local perVehicle = swings[vehicle]
	if not perVehicle then
		perVehicle = {}
		swings[vehicle] = perVehicle
	end
	local swing = perVehicle[mount]
	if not swing then
		swing = { yaw = 0, pitch = spec.restPitch or 0 }
		perVehicle[mount] = swing
	end
	local follow = GunnerView and GunnerView.Pure and GunnerView.Pure.follow
	if follow then
		-- Someone else's mount from a 10 Hz attribute: the same damped follow the gunner's own view uses,
		-- so it reads as a turret turning, never as steps (Oliver 09-24: "rotation ... smoother").
		local speed = math.min(SWING_RATE, (spec.slew or SWING_RATE) * 1.25)
		local accel = (spec.slewAccel or speed * 6)
		swing.yaw, swing.yawV = follow(swing.yaw, swing.yawV or 0, yawTarget, dt, speed, accel, false, 10)
		swing.pitch, swing.pitchV = follow(swing.pitch, swing.pitchV or 0, pitchTarget, dt, speed, accel, false, 10)
	else
		local step = SWING_RATE * dt
		swing.yaw = approach(swing.yaw, yawTarget, step)
		swing.pitch = approach(swing.pitch, pitchTarget, step)
	end
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

-- The gunner's view: started on the turret this player sits at, stopped on anything else.
local viewVehicle = nil
local function setView(vehicle, spec)
	if view and viewVehicle == vehicle then
		return
	end
	if view then
		view:Stop()
		view = nil
		viewVehicle = nil
	end
	if vehicle and GunnerView then
		local ok, started = pcall(GunnerView.Start, vehicle, spec)
		if ok and started then
			view, viewVehicle = started, vehicle
		elseif not ok then
			warn("[VehicleWeaponClient] the gunner's view didn't start: " .. tostring(started))
		end
	end
end

-- The mount's readout: rounds left and the bar, or for a gun that overheats, its heat.
local function showAmmo(spec, ammo, hot)
	local whole = math.floor(ammo)
	nameLabel.Text = spec.hud
	-- A mount with an infinite pool (the emplacements, MountedGunData) reads "belt / infinity" (Oliver 09-24:
	-- "make all guns including mounted ones have an infinite ammo pool, still have to reload").
	local pool = spec.infinitePool and "\u{221E}" or tostring(spec.magazine)
	if spec.overheat then
		local heat = math.clamp(1 - ammo / spec.magazine, 0, 1)
		ammoLabel.Text = hot and "OVERHEAT" or string.format("%d / %s", whole, pool)
		ammoLabel.TextColor3 = hot and Color3.fromRGB(255, 110, 70) or Color3.fromRGB(245, 245, 250)
		barFill.Size = UDim2.fromScale(heat, 1)
		barFill.BackgroundColor3 = Color3.fromRGB(255, math.floor(196 - 130 * heat), math.floor(64 - 40 * heat))
	else
		ammoLabel.Text = (spec.infinitePool and whole < 1) and "RELOADING" or string.format("%d / %s", whole, pool)
		ammoLabel.TextColor3 = whole < 1 and Color3.fromRGB(255, 96, 96) or Color3.fromRGB(245, 245, 250)
		barFill.Size = UDim2.fromScale(math.clamp(ammo / spec.magazine, 0, 1), 1)
		barFill.BackgroundColor3 = Color3.fromRGB(255, 196, 64)
	end
end

RunService.RenderStepped:Connect(function(dt)
	local mine, spec, mount = drivenVehicle()
	setBound(mine and mount or nil)
	gui.Enabled = mine ~= nil
	setView(mine and mount == "turret" and mine or nil, spec)
	if mine then
		followVehiclePanel()
	else
		setCursorHidden(false)
	end

	local now = workspace:GetServerTimeNow()
	if mine then
		local attributes = VehicleWeaponData.Attributes[mount]
		local ammo = VehicleWeaponData.AmmoAt(spec, mine:GetAttribute(attributes.ammo) or spec.magazine,
			mine:GetAttribute(attributes.firedAt), now)
		local hot = mine:GetAttribute(attributes.hot) == true and spec.overheat ~= nil and ammo < spec.magazine * spec.overheat
		local ready = ammo >= 1 and not hot
		local target
		if view then
			-- The gunner's first person: the view turns the turret itself and shows the sight.
			reticle.Visible = false
			setCursorHidden(false)
			view:Update(dt, { ready = ready })
			target = view:AimPoint()
		else
			reticle.Visible = true
			local screenX, screenY, mode = aimScreen()
			setCursorHidden(mode == "mouse" and player:GetAttribute("MenuOpen") ~= true)
			target = aimPoint(mine, screenX, screenY)
			placeReticle(screenX, screenY, false)
			-- The mount follows the aim straight away, by the server's own limits (VehicleWeaponData.Solve).
			local names = VehicleWeaponData.Parts[mount]
			local yawPart, pitchPart, muzzle = mine:FindFirstChild(names.yaw), mine:FindFirstChild(names.pitch), mine:FindFirstChild(names.muzzle)
			if yawPart and pitchPart then
				local joint = yawPart:FindFirstChild("Joint")
				-- The unswung mount frame: the yaw pivot's rest frame from its joint's parent.
				local rest = joint and joint.Part0 and joint.Part0.CFrame * joint.C0 or yawPart.CFrame
				-- The pitch pivot's rest place in the yaw frame (its joint's C0: it may stand out in front on a
				-- pintle) and the muzzle's in the pitch pivot's own frame -- read off the joints, not the parts,
				-- which are already swung.
				local pitchJoint = pitchPart:FindFirstChild("Joint")
				local pivot = pitchJoint and pitchJoint.C0.Position or rest:PointToObjectSpace(pitchPart.Position)
				local mouth = muzzle and pitchPart.CFrame:VectorToObjectSpace(muzzle.Position - pitchPart.Position) or Vector3.new(0, 0, -1)
				local toTarget = rest:PointToObjectSpace(target)
				local yaw, pitch, _origin, _direction = VehicleWeaponData.Solve(spec, rest, pivot, mouth, target)
				if yaw then
					swingMount(mine, mount, spec, math.deg(yaw), math.deg(pitch), dt * 3)
					-- Pinned when the wanted bearing and elevation (from the yaw axis and the pitch pivot) fall
					-- outside the arc: the arc's own clamp of them differs from them.
					local wantYaw = math.atan2(-toTarget.X, -toTarget.Z)
					local fromPivot = toTarget - pivot
					local wantPitch = math.atan2(fromPivot.Y, math.sqrt(fromPivot.X * fromPivot.X + fromPivot.Z * fromPivot.Z))
					local heldYaw = math.clamp(wantYaw, -math.rad(spec.yawLimit), math.rad(spec.yawLimit))
					local heldPitch = math.clamp(wantPitch, VehicleWeaponData.PitchFloor(spec, heldYaw), math.rad(spec.pitchMax))
					if pinnedToArc(wantYaw, wantPitch, heldYaw, heldPitch) then
						-- The mark goes where the gun can point: along the arc's edge, as far out as the aim.
						local dx, dy, dz = directionFromAngles(yaw, pitch)
						local edge = rest:PointToWorldSpace(pivot) + rest:VectorToWorldSpace(Vector3.new(dx, dy, dz)) * fromPivot.Magnitude
						local screen, onScreen = camera:WorldToViewportPoint(edge)
						if onScreen then
							placeReticle(screen.X, screen.Y, true)
						else
							placeReticle(screenX, screenY, true)
						end
					end
				end
			end
		end

		if firing and now - lastShotAt >= 1 / spec.fireRate and ready then
			lastShotAt = now
			lastAimAt = now -- the server takes the aim from the shot too
			fireRemote:FireServer(target)
			if view then
				view:Fired()
			end
		elseif now - lastAimAt >= AIM_SEND_EVERY then
			lastAimAt = now
			aimRemote:FireServer(target)
		end
		showAmmo(spec, ammo, hot)
	end

	-- Everyone else's mounts (and this player's other one), from what their users last sent; an
	-- unmanned one settles to rest.
	local eye = camera.CFrame.Position
	for _, vehicle in ipairs(CollectionService:GetTagged(TAG)) do
		if vehicle.PrimaryPart and (vehicle.PrimaryPart.Position - eye).Magnitude < 400 then
			local modelId = vehicle:GetAttribute("VehicleModel")
			for _, other in ipairs(VehicleWeaponData.Mounts) do
				local otherSpec = VehicleWeaponData.ForModel(modelId, other)
				if otherSpec and not (vehicle == mine and other == mount) then
					local seat = other == "turret" and gunnerSeatOf(vehicle) or vehicle:FindFirstChild("DriverSeat")
					local manned = seat ~= nil and seat.Occupant ~= nil
					local attributes = VehicleWeaponData.Attributes[other]
					local yaw = manned and vehicle:GetAttribute(attributes.yaw) or 0
					local pitch = manned and vehicle:GetAttribute(attributes.pitch) or otherSpec.restPitch or 0
					swingMount(vehicle, other, otherSpec, yaw, pitch, dt)
				end
			end
		end
	end
end)
