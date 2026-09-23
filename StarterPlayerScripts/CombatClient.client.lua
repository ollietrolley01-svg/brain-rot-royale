-- Shooting input, first-person camera lock during matches, and shot tracers.
-- The client only ever sends a direction; the server decides what it hit.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))

local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))
-- Up here rather than with the viewmodel section: the camera asks it which optic a gun carries.
local Viewmodel = require(script.Parent:WaitForChild("Viewmodel"))
local AimState = require(script.Parent:WaitForChild("AimState"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local fireRemote = Remotes.Event("Fire")
-- The lobby firing range: its own pair of remotes, so range shots never enter the match fire
-- path and the server's combat guard stays exactly as it is.
local rangeStateRemote = Remotes.Event("RangeState")
local rangeFireRemote = Remotes.Event("RangeFire")
local equipRemote = Remotes.Event("EquipSlot")
local reloadRemote = Remotes.Event("ReloadWeapon")
local useRemote = Remotes.Event("UseSelected")
local loadoutChanged = Remotes.Event("LoadoutChanged")
local matchChanged = Remotes.Event("MatchChanged")
local shotFired = Remotes.Event("ShotFired")

local loadout = nil
local matchState = "Waiting"
local firing = false

-- Which input started the current trigger pull and the current aim, so the loops below can ask
-- whether the button is still physically down.
--
-- ContextActionService sends Cancel to an action whenever something binds the same input above
-- it, and Roblox's own camera module rebinds its controls every time the camera mode changes --
-- which is exactly what aiming a scoped gun does, through updateCameraMode. Reading that Cancel
-- as "you let go" is what cut full auto out part way through a burst and stopped ADS being
-- holdable at all. Cancel is ignored now and the button's real state decides instead. A
-- cancelled action never delivers its End either, so without the polling the trigger would
-- simply stick on.
local fireInput = nil
local aimInput = nil

local function stillHeld(inputType, gamepadButton)
	if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.MouseButton2 then
		return UserInputService:IsMouseButtonPressed(inputType)
	elseif inputType == Enum.UserInputType.Gamepad1 then
		return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, gamepadButton)
	end
	-- Touch, and anything else with no state to poll: trust the End that CAS will deliver.
	return true
end

local lastLocalShot = 0
-- Client-side mirror of the server's weapon raise time. Without it, firing right after a
-- swap sent shots the server rejected while recoil still kicked the camera — a phantom
-- shot with no bullet and no ammo change.
local localEquipReadyAt = 0
local spectating = false
local spectateIndex = 1

local effects = Instance.new("Folder")
effects.Name = "Effects"
effects.Parent = workspace

-- True while you're holding a gun from the lobby firing range. The range is the one place you
-- can shoot outside a match, so it gets its own flag rather than pretending a match is running.
-- The server owns it: it turns on when the rack hands you a gun and off when you walk off the
-- terrace, so there is nothing here a client can set for itself.
local rangeActive = false

local function inCombat()
	-- An open menu counts as out of combat: the mouse must be free to click it, and those
	-- clicks must not reach the fire binding.
	if spectating or (matchState ~= "InProgress" and not rangeActive) or not loadout or player:GetAttribute("MenuOpen") then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function equippedDef()
	if not loadout or not loadout.equipped then
		return nil
	end
	local slot = loadout.slots[loadout.equipped]
	return slot and slot.kind == "weapon" and WeaponData.Get(slot.id) or nil
end

-- The held slot when it's an item stack rather than a gun.
local function equippedItemSlot()
	local slot = loadout and loadout.equipped and loadout.slots[loadout.equipped]
	return slot and slot.kind == "item" and slot or nil
end

--------------------------------------------------------------------------------
-- Camera
--
-- Matches are first person by default. The Settings toggle (or its key) switches to an
-- over-the-shoulder third person: the camera hangs behind and to the right of the character, the
-- mouse stays locked to the centre, and the character turns to face wherever you look, so the
-- crosshair means exactly what it means in first person. Scoped guns drop back into first person
-- while you aim, so the scope view works the same in both modes.
--
-- Third person drives the camera itself (CameraType.Scriptable): yaw and pitch are integrated from
-- the mouse, the camera is pulled in toward the shoulder whenever a wall would get between them,
-- and the recoil offsets layered on around the camera update work unchanged. First person hands
-- the camera back to Roblox's default camera.
--------------------------------------------------------------------------------

-- Declared here because the camera has to know about them; they're driven further down.
local aiming = false
-- Scoped guns zoom much further than iron sights and red dots: how far by style, for a gun whose model
-- actually carries a scope (a marksman-style gun with a red dot or holo aims like one).
local SCOPE_ZOOM = { sniper = 0.3, dmr = 0.45, railgun = 0.4 }
local DEFAULT_SCOPE_ZOOM = 0.4

local THIRD_PERSON_DISTANCE = 9
local THIRD_PERSON_AIM_DISTANCE = 4.5
-- Where the camera pivots, relative to the root: up to eye height and out over the right shoulder.
-- Aiming brings it in over the shoulder so the gun sits under the crosshair.
local SHOULDER_HEIGHT = 1.7
local SHOULDER_SIDE = 1.9
local SHOULDER_AIM_SIDE = 1.2
local PITCH_LIMIT = math.rad(78)
-- Radians per pixel, the same as Roblox's own camera, scaled by the look sensitivity settings
-- through UserInputService.MouseDeltaSensitivity.
local LOOK_SENSITIVITY = Vector2.new(0.002 * math.pi, 0.0015 * math.pi)
local GAMEPAD_LOOK_SPEED = 2.6
local TOUCH_LOOK_SCALE = 1.6
-- How far short of a wall the camera stops, so the near plane never cuts through it.
local CAMERA_CLEARANCE = 0.6

-- The mouse wheel zooms: out of first person into third, further out in steps to ZOOM_MAX, and
-- back in past ZOOM_MIN to first person again.
local ZOOM_MIN, ZOOM_MAX, ZOOM_STEP = 5, 17, 2

local thirdPersonActive = false
local lookYaw, lookPitch = 0, 0
local zoomDistance = THIRD_PERSON_DISTANCE
local shoulderDistance = THIRD_PERSON_DISTANCE
local gamepadLook = Vector2.zero
local touchDelta = Vector2.zero

-- The zoom of the scope on the gun in hand, or nil when it has none. The optic comes from the held
-- model's own Optic attribute (GunModels sets it), from the viewmodel's template while the held model is
-- still arriving, or failing both from the style.
local function scopeZoom()
	local def = equippedDef()
	if not def then
		return nil
	end
	local character = player.Character
	local held = character and character:FindFirstChild("HeldGun")
	local optic = held and held:GetAttribute("WeaponId") == def.id and held:GetAttribute("Optic") or nil
	optic = optic or Viewmodel.OpticOf(def)
	if optic == nil then
		return SCOPE_ZOOM[def.style]
	end
	return optic == "scope" and (SCOPE_ZOOM[def.style] or DEFAULT_SCOPE_ZOOM) or nil
end

local function scopedWeapon()
	return scopeZoom() ~= nil
end

-- Third person unless the setting is off, or a scoped gun is being aimed.
local function wantsThirdPerson()
	return Settings.Get("ThirdPerson") == true and not (aiming and scopedWeapon())
end

-- What the camera may not pass through: solid world only. Your own character, effects, loot
-- pickups, companions and launch pads are all things the camera should sit inside of freely.
local function cameraOcclusionParams(character)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local filter = { character, effects, camera }
	for _, name in ipairs({ "Loot", "Companions", "Deployables" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(filter, folder)
		end
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- The furthest point from `from` toward `to` that nothing solid is in the way of.
local function clearPoint(from, to, params)
	local offset = to - from
	if offset.Magnitude < 0.01 then
		return to
	end
	local hit = workspace:Raycast(from, offset, params)
	if not hit then
		return to
	end
	local distance = math.max(0, (hit.Position - from).Magnitude - CAMERA_CLEARANCE)
	return from + offset.Unit * distance
end

local function updateThirdPersonCamera(delta)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end

	-- Roblox's camera module unlocks the mouse when it sees a Scriptable camera, so keep it locked.
	if not player:GetAttribute("MenuOpen") then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end

	local mouse = UserInputService:GetMouseDelta() + touchDelta * TOUCH_LOOK_SCALE
	touchDelta = Vector2.zero
	lookYaw -= mouse.X * LOOK_SENSITIVITY.X + gamepadLook.X * GAMEPAD_LOOK_SPEED * delta
	lookPitch = math.clamp(lookPitch - mouse.Y * LOOK_SENSITIVITY.Y + gamepadLook.Y * GAMEPAD_LOOK_SPEED * delta,
		-PITCH_LIMIT, PITCH_LIMIT)

	-- The character turns with the camera, the way shift lock does, so moving and shooting happen
	-- in the direction you're looking. Only the rotation is written; position and velocity stay.
	if humanoid.Health > 0 then
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, lookYaw, 0)
	end

	local targetDistance = aiming and THIRD_PERSON_AIM_DISTANCE or zoomDistance
	shoulderDistance += (targetDistance - shoulderDistance) * math.clamp(delta * 10, 0, 1)
	local side = aiming and SHOULDER_AIM_SIDE or SHOULDER_SIDE

	local look = CFrame.Angles(0, lookYaw, 0) * CFrame.Angles(lookPitch, 0, 0)
	local params = cameraOcclusionParams(character)
	-- Humanoid.CameraOffset moves this camera the way it moves Roblox's own (in the body's frame), so a
	-- slide's camera drop shows in third person too.
	local base = root.Position + Vector3.new(0, SHOULDER_HEIGHT, 0) + root.CFrame:VectorToWorldSpace(humanoid.CameraOffset)
	-- Out to the shoulder first, then back from there, each leg stopping short of any wall.
	local shoulder = clearPoint(base, base + look.RightVector * side, params)
	local position = clearPoint(shoulder, shoulder - look.LookVector * shoulderDistance, params)

	camera.CFrame = CFrame.lookAt(position, position + look.LookVector)
	camera.Focus = CFrame.new(shoulder)
end

-- `nextIsFirstPerson` says what the camera goes back to when third person ends, so the body's
-- transparency can be left the way Roblox's camera expects it (see below).
local function setThirdPerson(active, nextIsFirstPerson)
	if thirdPersonActive == active then
		return
	end
	thirdPersonActive = active
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	-- Roblox's camera stops updating the body's first-person transparency while the camera is
	-- scriptable, and only re-applies it when its cached value changes. Set the body ourselves:
	-- visible in third person, hidden again if first person is next, so neither mode is left with
	-- the other's body.
	local function setBodyTransparency(value)
		if not character then
			return
		end
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") or part:IsA("Decal") then
				part.LocalTransparencyModifier = value
			end
		end
	end

	if active then
		-- Carry on looking the way the camera already points, so the switch doesn't jolt.
		local look = camera.CFrame.LookVector
		lookYaw = math.atan2(-look.X, -look.Z)
		lookPitch = math.clamp(math.asin(math.clamp(look.Y, -1, 1)), -PITCH_LIMIT, PITCH_LIMIT)
		shoulderDistance = aiming and THIRD_PERSON_AIM_DISTANCE or zoomDistance
		camera.CameraType = Enum.CameraType.Scriptable
		if humanoid then
			humanoid.AutoRotate = false
		end
		setBodyTransparency(0)
		RunService:BindToRenderStep("BRR_ThirdPerson", Enum.RenderPriority.Camera.Value, updateThirdPersonCamera)
	else
		RunService:UnbindFromRenderStep("BRR_ThirdPerson")
		if humanoid then
			humanoid.AutoRotate = true
		end
		setBodyTransparency(nextIsFirstPerson and 1 or 0)
		camera.CameraType = Enum.CameraType.Custom
	end
end

local function updateCameraMode()
	-- In a vehicle its own chase camera drives the view and the mouse: ours stands down, leaving the camera
	-- Classic and the mouse alone. VehicleService owns the InVehicle attribute (it clears it on leaving,
	-- death and respawn); VehicleClient sets it early on the driver so the handover isn't a beat late.
	if player:GetAttribute("InVehicle") then
		setThirdPerson(false, false)
		player.CameraMode = Enum.CameraMode.Classic
		return
	end
	if inCombat() then
		if wantsThirdPerson() then
			player.CameraMode = Enum.CameraMode.Classic
			setThirdPerson(true)
		else
			setThirdPerson(false, true)
			player.CameraMode = Enum.CameraMode.LockFirstPerson
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	else
		setThirdPerson(false, false)
		player.CameraMode = Enum.CameraMode.Classic
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end
player:GetAttributeChangedSignal("InVehicle"):Connect(function()
	updateCameraMode()
end)

-- Gamepad right stick and touch drags steer the third-person camera; the mouse is read directly
-- in the camera update.
UserInputService.InputChanged:Connect(function(input, processed)
	if not thirdPersonActive then
		return
	end
	if input.UserInputType == Enum.UserInputType.Gamepad1 and input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local stick = input.Position
		gamepadLook = stick.Magnitude > 0.15 and Vector2.new(stick.X, stick.Y) or Vector2.zero
	elseif input.UserInputType == Enum.UserInputType.Touch and not processed then
		touchDelta += Vector2.new(input.Delta.X, input.Delta.Y)
	end
end)

-- The gun is welded in front of the torso, which in first person puts it directly in front
-- of the camera — and an accessory sits right on the head the camera is inside. Roblox hides
-- body parts there via LocalTransparencyModifier but not welded models like these, so hide
-- our own copies locally. Other players still see them, and so do you in third person.
local HIDE_IN_FIRST_PERSON = { "HeldGun", "HeldItem", "CosmeticAccessory" }
local hiddenModels, hiddenValues = {}, {}

RunService.RenderStepped:Connect(function()
	local character = player.Character
	local hide = player.CameraMode == Enum.CameraMode.LockFirstPerson and 1 or 0

	for _, name in ipairs(HIDE_IN_FIRST_PERSON) do
		local model = character and character:FindFirstChild(name)
		if not model then
			hiddenModels[name] = nil
		-- Only touch the parts when the model or the camera mode actually changed. Walking every
		-- descendant each frame allocated a new table sixty times a second for no visible change.
		elseif model ~= hiddenModels[name] or hide ~= hiddenValues[name] then
			hiddenModels[name], hiddenValues[name] = model, hide
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = hide
				end
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Spectating
--------------------------------------------------------------------------------

local spectateRemote = Remotes.Event("Spectate")

-- Characters replicate to the client, so the living can be found without the server
-- maintaining a spectator list.
local function livingCharacters()
	local found = {}
	for _, model in ipairs(workspace:GetChildren()) do
		if model:IsA("Model") and model ~= player.Character then
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			local root = model:FindFirstChild("HumanoidRootPart")
			-- #102: only THIS match's combatants, alive right now. The match test is the `InMatch`
			-- attribute MatchService writes on every Player (true for the match's players, false for
			-- lobby idlers, mid-match joiners and anyone who has left); bots have no Player and fall
			-- through the nil. An ABSENT attribute counts as in, so wherever the server has not written
			-- this reads as today's behaviour -- never as "bots only". The alive test is separate:
			-- InMatch is not cleared on death, so a dead spectator still cycles to the living.
			local owner = Players:GetPlayerFromCharacter(model)
			local inMatch = owner == nil or owner:GetAttribute("InMatch") ~= false
			if humanoid and root and humanoid.Health > 0 and inMatch then
				table.insert(found, { model = model, humanoid = humanoid })
			end
		end
	end
	table.sort(found, function(a, b)
		return a.model.Name < b.model.Name
	end)
	return found
end

local focusRemote = Remotes.Event("SetReplicationFocus")

local function applySpectateTarget()
	local targets = livingCharacters()
	if #targets == 0 then
		camera.CameraType = Enum.CameraType.Fixed
		focusRemote:FireServer(nil)
		return nil
	end

	spectateIndex = ((spectateIndex - 1) % #targets) + 1
	local entry = targets[spectateIndex]

	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = entry.humanoid

	-- Ask the server to stream the world around them, not around our dead body.
	focusRemote:FireServer(entry.model:FindFirstChild("HumanoidRootPart"))
	return entry.model.Name
end

local spectateLabel = nil

local function setSpectating(value)
	spectating = value

	if not spectating then
		if spectateLabel then
			spectateLabel.Parent:Destroy()
			spectateLabel = nil
		end
		camera.CameraType = Enum.CameraType.Custom
		focusRemote:FireServer(nil)
		updateCameraMode()
		return
	end

	player.CameraMode = Enum.CameraMode.Classic
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default

	local gui = Instance.new("ScreenGui")
	gui.Name = "SpectateHud"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	spectateLabel = Instance.new("TextLabel")
	spectateLabel.AnchorPoint = Vector2.new(0.5, 1)
	spectateLabel.Position = UDim2.new(0.5, 0, 1, -24)
	-- Wide enough for "Spectating <name>   •   [E] next   •   [L] leave" at GothamBold 16, and wrapped
	-- rather than spilling past the rounded plate when the name is long (#102).
	spectateLabel.Size = UDim2.fromOffset(620, 48)
	spectateLabel.TextWrapped = true
	spectateLabel.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	spectateLabel.BackgroundTransparency = 0.2
	spectateLabel.BorderSizePixel = 0
	spectateLabel.Font = Enum.Font.GothamBold
	spectateLabel.TextColor3 = Color3.fromRGB(240, 242, 248)
	spectateLabel.TextSize = 16
	spectateLabel.Text = "Spectating"
	spectateLabel.Parent = gui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = spectateLabel

	local name = applySpectateTarget()
	spectateLabel.Text = name
		and string.format("Spectating %s   •   [%s] next   •   [%s] leave", name, Settings.KeyLabel("SpectateNext"), Settings.KeyLabel("SpectateLeave"))
		or string.format("No one left to watch   •   [%s] back to the lobby", Settings.KeyLabel("SpectateLeave"))
end

local function cycleSpectate(step)
	if not spectating then
		return
	end
	spectateIndex += step
	local name = applySpectateTarget()
	if spectateLabel then
		spectateLabel.Text = name
			and string.format("Spectating %s   •   [%s] next   •   [%s] leave", name, Settings.KeyLabel("SpectateNext"), Settings.KeyLabel("SpectateLeave"))
			or string.format("No one left to watch   •   [%s] back to the lobby", Settings.KeyLabel("SpectateLeave"))
	end
end

spectateRemote.OnClientEvent:Connect(setSpectating)

Settings.Bind("BRR_SpectateNext", "SpectateNext", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and spectating then
		cycleSpectate(1)
	end
	return Enum.ContextActionResult.Pass
end)

-- #102: the way OUT. The server owns the decision (MatchService.LeaveSpectate refuses anyone who is
-- not spectating, and the remote is rate-limited) and answers with Spectate(false) BEFORE the new body,
-- so the camera is handed back first; nothing is torn down here on the press.
local leaveSpectateRemote = Remotes.Event("LeaveSpectate")
Settings.Bind("BRR_SpectateLeave", "SpectateLeave", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and spectating then
		Sfx.Play("UiClick", 0.08)
		leaveSpectateRemote:FireServer()
	end
	return Enum.ContextActionResult.Pass
end)

-- Follow someone else automatically when the current subject dies.
task.spawn(function()
	while true do
		task.wait(1)
		if spectating then
			local subject = camera.CameraSubject
			if not subject or not subject:IsA("Humanoid") or subject.Health <= 0 then
				cycleSpectate(1)
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

-- Returns the world point under the crosshair. The server fires from the head toward this
-- point, so the shot converges on exactly what you're aiming at regardless of where the
-- camera sits relative to the head.
--
-- Two things matter here:
--  * ViewportPointToRay, not ScreenPointToRay. The crosshair lives in an IgnoreGuiInset gui,
--    so its centre is the viewport centre; ScreenPointToRay would sample a point shifted
--    down by the top-bar inset.
--  * Raycast to the real surface. Aiming at a fixed point 2000 studs down the camera ray and
--    firing at it from the head sent shots into the ground whenever the camera looked down
--    at the character, because the head and camera aren't in the same place.
local function crosshairPoint()
	local character = player.Character
	if not character then
		return nil
	end

	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)

	-- Must ignore the same things the server's shot raycast ignores, or the crosshair can
	-- lock onto a floating loot pickup and pull the shot off the real target behind it.
	local filter = { character, effects }
	local loot = workspace:FindFirstChild("Loot")
	if loot then
		table.insert(filter, loot)
	end
	-- The server's shots pass through your own companion, so the crosshair has to as well.
	local companions = workspace:FindFirstChild("Companions")
	if companions then
		for _, model in ipairs(companions:GetChildren()) do
			if model:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(filter, model)
			end
		end
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Terrain water doesn't stop a bullet, and THIS TRACE DECIDES WHERE THE SHOT IS AIMED, so it has
	-- to pass through water exactly like the server's shot ray (CombatService.buildRaycastParams) and
	-- the launcher rounds (ProjectileService). Left at its default FALSE it stopped at the surface, so
	-- aiming across a river snapped the aim point onto the water and the server then fired
	-- head->surface and diverged from the crosshair line beyond it -- #97.
	params.IgnoreWater = true
	params.FilterDescendantsInstances = filter

	local result = workspace:Raycast(ray.Origin, ray.Direction * 1500, params)
	if result then
		return result.Position
	end
	return ray.Origin + ray.Direction * 1500
end

-- The aim every shot, throw and companion command sends, recorded in AimState so other client scripts
-- (the placement preview) aim exactly the same way.
local function aimPoint()
	local point = crosshairPoint()
	AimState.Point = point
	return point
end
AimState.SetResolver(aimPoint)

-- Defined below, alongside the decay loop and the viewmodel.
local addRecoil
local kickViewmodel

-- Pulling the trigger on an empty magazine reloads instead of clicking uselessly (the
-- "AutoReload" setting). Asked once per dry pull; the server refuses if there's no ammo left.
local autoReloadAskedAt = 0

-- The driver has both hands on the wheel, and a gamepad's triggers are the throttle and brake: while
-- driving, the fire and aim bindings neither shoot, click nor aim (they still pass the input on to the
-- vehicle). Passengers can do both.
local function drivingVehicle()
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.SeatPart ~= nil and humanoid.SeatPart:IsA("VehicleSeat")
end

local function tryFire()
	if not inCombat() then
		return
	end
	if drivingVehicle() then
		return
	end

	local def = equippedDef()
	if not def or loadout.reloading then
		return
	end

	local slot = loadout.slots[loadout.equipped]
	if not slot then
		return
	end
	if slot.mag <= 0 then
		local now = os.clock()
		if Settings.Get("AutoReload") and now - autoReloadAskedAt > 0.6 then
			autoReloadAskedAt = now
			reloadRemote:FireServer()
		end
		return
	end

	-- Mirror the server's raise time so we don't send shots it will reject.
	local now = os.clock()
	if now < localEquipReadyAt then
		return
	end
	local interval = 1 / def.fireRate
	if now - lastLocalShot < interval then
		return
	end
	-- ADVANCE BY A WHOLE INTERVAL; NEVER RESET TO `now`. This runs on Heartbeat, so a shot lands on
	-- the first frame at or after the interval. Resetting to `now` threw the leftover away and
	-- quantised the fire rate down to the FRAME RATE: computed across all 27 weapons in WeaponData,
	-- the 14/s Glitch SMG delivered 12.00/s at 60 fps (-14.3%) and 10.00/s at 30 fps (-28.6%), so a
	-- 30 fps player's SMG did 28.6% less damage than a 60 fps player's for no reason anyone could
	-- see. Carrying the remainder forward holds the average at fireRate whatever the frame rate.
	--
	-- This is only safe together with the server's shot BUDGET (CombatService.ShotCredit): sends now
	-- land one interval apart give or take a frame, which the old strict `interval * 0.9` server gate
	-- would have rejected outright. Landing either change without the other makes #97 worse.
	lastLocalShot += interval
	if now - lastLocalShot > interval then
		-- Coming off a pause or a frame hitch: start fresh rather than banking credit for a burst.
		lastLocalShot = now
	end

	local target = aimPoint()
	if target then
		-- Sample the target first, then kick: the shot goes where you were aiming.
		if rangeActive then
			rangeFireRemote:FireServer(target)
		else
			fireRemote:FireServer(target)
		end
		addRecoil(def)
		kickViewmodel(def)
	end
end

RunService.Heartbeat:Connect(function()
	if not firing then
		return
	end
	-- Re-checked against the real button, because a cancelled binding never delivers its End.
	if not stillHeld(fireInput, Enum.KeyCode.ButtonR2) then
		firing = false
		return
	end
	tryFire()
end)

--------------------------------------------------------------------------------
-- Recoil
--
-- Applied as a camera offset that decays back to zero, so it kicks the view without
-- desyncing where the server thinks you're aiming — the shot direction is sampled at fire
-- time, before the kick lands.
--------------------------------------------------------------------------------

local recoilPitch = 0
local recoilYaw = 0

-- Crouched and holding still, the gun is steadier. The server owns the SPREAD half of that
-- (CombatService.SpreadFor is what Fire actually shoots with); the camera kick is the shooter's own
-- client, so it fades here off the same numbers in MovementConfig.Crouch rather than a second copy of
-- them, and it mirrors the server's fade exactly: in over SteadyFade while barely moving, out again
-- otherwise, and gone the instant the crouch is, whatever the fade had reached.
--
-- The crouch comes from the character ATTRIBUTE the server set, not from the local prediction, so the
-- kick and the spread are always talking about the same crouch.
local CROUCH_STEADY = MovementConfig.Crouch
local steadyFactor = 0

RunService.Heartbeat:Connect(function(delta)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = humanoid and humanoid.RootPart
	if not root or humanoid.Health <= 0 or character:GetAttribute("Crouching") ~= true then
		steadyFactor = 0
		return
	end
	local velocity = root.AssemblyLinearVelocity
	local flatSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local step = math.min(delta, 0.1) / math.max(CROUCH_STEADY.SteadyFade, 0.01)
	if flatSpeed <= MatchConfig.BaseWalkSpeed * CROUCH_STEADY.SteadyMoveFraction then
		steadyFactor = math.min(1, steadyFactor + step)
	else
		steadyFactor = math.max(0, steadyFactor - step)
	end
end)

-- Spray (Oliver, 2026-09-22: "the guns need a recoil and accuracy dropoff as they shoot like in other
-- similar games"). Each shot of an unbroken spray kicks harder than the last and sideways drift grows,
-- and while the trigger stays down the kick only half-recovers between shots, so the view (and the aim,
-- which is read from the camera) climbs and the player pulls down against it. Let go and it settles.
-- The server widens the spread the same way (CombatService bloom).
local spray = { shots = 0, lastAt = 0 }

function addRecoil(def)
	local now = os.clock()
	if now - spray.lastAt > math.max(0.3, 2.2 / math.max(def.fireRate, 0.1)) then
		spray.shots = 0
	end
	spray.lastAt = now
	spray.shots += 1
	-- Heavier, slower weapons kick harder; a 13/sec chaingun would be unusable otherwise.
	local kick = math.clamp(def.damage / 60, 0.25, 2.2) / math.max(1, def.fireRate * 0.35)
	kick *= 1 - (1 - CROUCH_STEADY.SteadyRecoil) * steadyFactor
	kick *= 1 + math.min((spray.shots - 1) * 0.12, 1.2)
	if aiming then
		kick *= 0.7
	end
	recoilPitch = math.min(recoilPitch + math.rad(kick * 1.7), math.rad(14))
	recoilYaw += math.rad((math.random() - 0.5) * kick * 1.4 * (1 + math.min(spray.shots * 0.06, 0.8)))
end

-- Two passes around Roblox's camera update. The default camera module reads
-- camera.CFrame.LookVector back at the start of every frame and builds the next view from it,
-- so a kick applied once after that update got treated as the new aim: each shot permanently
-- integrated several times its intended kick, and the view climbed while firing and never
-- came back.
--
-- So take last frame's kick off just before the camera module runs, and put the current
-- decayed kick on just after. The camera module only ever sees true aim, and the offset is
-- purely visual — it returns to zero exactly as it decays.
local appliedRecoil = nil

RunService:BindToRenderStep("BRR_RecoilUndo", Enum.RenderPriority.Camera.Value - 1, function()
	if appliedRecoil then
		camera.CFrame = camera.CFrame * appliedRecoil:Inverse()
		appliedRecoil = nil
	end
end)

RunService:BindToRenderStep("BRR_Recoil", Enum.RenderPriority.Camera.Value + 1, function(delta)
	if recoilPitch <= 0.0001 and math.abs(recoilYaw) <= 0.0001 then
		recoilPitch, recoilYaw = 0, 0
		return
	end

	local offset = CFrame.Angles(recoilPitch, recoilYaw, 0)
	camera.CFrame = camera.CFrame * offset
	appliedRecoil = offset

	-- Mid-spray the kick barely recovers, so it builds; once the trigger is let go it settles fast.
	local spraying = os.clock() - spray.lastAt < 0.18
	local decay = math.clamp(delta * (spraying and 3 or 12), 0, 1)
	recoilPitch -= recoilPitch * decay
	recoilYaw -= recoilYaw * decay
end)

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

ContextActionService:BindAction("BRR_Fire", function(_, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin and drivingVehicle() then
		return Enum.ContextActionResult.Pass
	elseif inputState == Enum.UserInputState.Begin then
		-- With an item in hand a click uses it; the server times the use and applies it. Where
		-- you're aiming goes along, for the ones that get thrown.
		if inCombat() and equippedItemSlot() then
			useRemote:FireServer(aimPoint())
			return Enum.ContextActionResult.Pass
		end
		fireInput = inputObject and inputObject.UserInputType or nil
		firing = true
		-- An empty gun clicks, once per pull of the trigger rather than once per fire tick.
		local emptyDef = inCombat() and equippedDef()
		local emptySlot = emptyDef and loadout.slots[loadout.equipped]
		if emptySlot and emptySlot.mag <= 0 and not loadout.reloading then
			Sfx.Play("DryFire", 0.05)
		end
		tryFire()
	elseif inputState == Enum.UserInputState.End then
		-- Cancel deliberately does not stop firing; see stillHeld above.
		firing = false
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

ContextActionService:SetTitle("BRR_Fire", "FIRE")
ContextActionService:SetPosition("BRR_Fire", UDim2.new(1, -140, 1, -180))

--------------------------------------------------------------------------------
-- Aiming down sights
--------------------------------------------------------------------------------

-- Aiming and sprinting each cancel the other, but they're set up in separate blocks, so
-- both need declaring up front.
local sprinting = false
local setSprinting

local aimRemote = Remotes.Event("SetAiming")
-- Aiming zooms to about two thirds of the field of view chosen in Settings.
local ADS_ZOOM = 0.64
-- `aiming` and scopeZoom are declared up in the camera section, which needs them first.
local function adsZoom()
	return scopeZoom() or ADS_ZOOM
end

local function applyLookSensitivity()
	UserInputService.MouseDeltaSensitivity = Settings.Get("LookSensitivity") * (aiming and Settings.Get("AimSensitivity") or 1)
end

local function setAiming(value)
	if aiming == value then
		return
	end
	aiming = value

	aimRemote:FireServer(aiming)
	applyLookSensitivity()
	-- Aiming a scoped gun in third person drops into first person for the scope view.
	updateCameraMode()
	local fov = Settings.Get("FieldOfView")
	TweenService:Create(camera, TweenInfo.new(0.16), {
		FieldOfView = aiming and fov * adsZoom() or fov,
	}):Play()
end

Settings.Changed:Connect(function(id)
	if id == "*" or id == "FieldOfView" then
		local fov = Settings.Get("FieldOfView")
		camera.FieldOfView = aiming and fov * adsZoom() or fov
	end
	if id == "*" or id == "LookSensitivity" or id == "AimSensitivity" then
		applyLookSensitivity()
	end
	if id == "*" or id == "ThirdPerson" then
		updateCameraMode()
	end
end)

-- Flip between first and third person. It's a saved setting, so the choice sticks between matches.
local function toggleCamera()
	if not player:GetAttribute("MenuOpen") then
		Settings.Set("ThirdPerson", not Settings.Get("ThirdPerson"))
	end
end
Settings.Bind("BRR_ToggleCamera", "ToggleCamera", function(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		toggleCamera()
	end
	return Enum.ContextActionResult.Pass
end, nil, Enum.KeyCode.DPadUp)

-- On a touch screen CAM is a small HUD button at the top right, not a ContextActionService button:
-- ContextActionService draws at most seven touch buttons, the game binds eight, and whichever bound last
-- came up blank. (A shared TouchControls module is planned for every touch button; this moves to it.)
if UserInputService.TouchEnabled then
	local camGui = Instance.new("ScreenGui")
	camGui.Name = "CameraToggleButton"
	camGui.ResetOnSpawn = false
	camGui.DisplayOrder = 5
	local camButton = Instance.new("TextButton")
	camButton.Name = "Cam"
	camButton.Size = UDim2.fromOffset(44, 44)
	camButton.Position = UDim2.new(1, -160, 0, 6)
	camButton.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	camButton.BackgroundTransparency = 0.35
	camButton.BorderSizePixel = 0
	camButton.Font = Enum.Font.GothamBold
	camButton.TextSize = 13
	camButton.TextColor3 = Color3.fromRGB(240, 242, 248)
	camButton.Text = "CAM"
	camButton.Parent = camGui
	local camCorner = Instance.new("UICorner")
	camCorner.CornerRadius = UDim.new(0, 10)
	camCorner.Parent = camButton
	camButton.Activated:Connect(toggleCamera)
	-- Out of the way while a menu is open (the toggle does nothing then anyway): a HUD button, unlike the
	-- core touch buttons, could sit over a panel's own controls.
	local function showCamButton()
		camGui.Enabled = not player:GetAttribute("MenuOpen")
	end
	player:GetAttributeChangedSignal("MenuOpen"):Connect(showCamButton)
	showCamButton()
	camGui.Parent = player:WaitForChild("PlayerGui")
end

ContextActionService:BindAction("BRR_Aim", function(_, inputState, inputObject)
	if inputState == Enum.UserInputState.Begin and inCombat() and not drivingVehicle() then
		if sprinting then
			setSprinting(false)
		end
		aimInput = inputObject and inputObject.UserInputType or nil
		setAiming(true)
	elseif inputState == Enum.UserInputState.End then
		-- Cancel deliberately does not drop the scope; see stillHeld above. Aiming a scoped gun
		-- changes the camera mode, which rebinds Roblox's camera controls, which cancelled this
		-- very action a frame after it started -- so ADS could never be held.
		setAiming(false)
	end
	return Enum.ContextActionResult.Pass
end, true, Enum.UserInputType.MouseButton2, Enum.KeyCode.ButtonL2)

-- The same guard the trigger uses: a cancelled binding never delivers its End, so without this
-- the scope would stay up after the button was released.
RunService.Heartbeat:Connect(function()
	-- Also dropped on taking a driver's seat while aimed.
	if aiming and (not stillHeld(aimInput, Enum.KeyCode.ButtonL2) or drivingVehicle()) then
		setAiming(false)
	end
end)

ContextActionService:SetTitle("BRR_Aim", "AIM")
ContextActionService:SetPosition("BRR_Aim", UDim2.new(1, -250, 1, -180))

--------------------------------------------------------------------------------
-- Sprinting
--------------------------------------------------------------------------------

local sprintRemote = Remotes.Event("SetSprinting")
-- Stamina, the slide, climbing and vaulting run in MovementClient; this is the table it shares.
local MovementState = require(script.Parent:WaitForChild("MovementState"))
-- When a match-state broadcast means "leave combat" and when it is just the lobby ticker repeating
-- itself. Pure, and tested by tools/combat_state_probe.lua.
local CombatState = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CombatState"))

function setSprinting(value)
	if sprinting == value then
		return
	end
	sprinting = value
	MovementState.sprinting = value
	sprintRemote:FireServer(sprinting)
end

-- Keyboard keys for everything below come from Settings and follow rebinds; the gamepad buttons
-- passed after each handler stay fixed.
-- On a keyboard sprint is held. The touch RUN button and a gamepad's stick click TOGGLE it instead: a
-- phone player's right thumb can't hold RUN and press SLIDE at once (the left is on the stick), and
-- clicking the stick in is how every console game sprints.
Settings.Bind("BRR_Sprint", "Sprint", function(_, inputState, inputObject)
	local toggles = inputObject ~= nil
		and (inputObject.UserInputType == Enum.UserInputType.Touch or inputObject.KeyCode == Enum.KeyCode.ButtonL3)
	local turnOn
	if toggles then
		if inputState ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		-- On, or waiting out exhaustion, means the tap turns it off; otherwise (including after aiming
		-- dropped it) the tap turns it on.
		turnOn = not (sprinting or (MovementState.sprintHeld and MovementState.exhausted))
	elseif inputState == Enum.UserInputState.Begin then
		turnOn = true
	elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		turnOn = false
	else
		return Enum.ContextActionResult.Pass
	end
	if turnOn then
		MovementState.SetSprintHeld(true)
		-- Sprinting and aiming are mutually exclusive; sprinting drops the scope.
		if aiming then
			setAiming(false)
		end
		-- Out of stamina the request is remembered but the sprint waits (see below).
		setSprinting(MovementState.CanSprint())
	else
		MovementState.SetSprintHeld(false)
		setSprinting(false)
	end
	return Enum.ContextActionResult.Pass
end, { title = "RUN", position = UDim2.new(1, -250, 1, -280) }, Enum.KeyCode.ButtonL3)

-- Running out of stamina drops the sprint; once it has recovered the sprint comes back by itself if
-- the key is still held (and you haven't started aiming meanwhile).
MovementState.SprintAllowedChanged:Connect(function(allowed)
	if not allowed then
		setSprinting(false)
	elseif MovementState.sprintHeld and not aiming then
		setSprinting(true)
	end
end)

-- A toggled sprint never survives a respawn, a death, sitting down in a vehicle or the menu opening
-- (MovementClient asks); tap RUN again afterwards.
MovementState.SprintOffRequested:Connect(function()
	MovementState.SetSprintHeld(false)
	setSprinting(false)
end)

Settings.Bind("BRR_Reload", "Reload", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and inCombat() then
		reloadRemote:FireServer()
	end
	return Enum.ContextActionResult.Pass
end, { title = "RELOAD", position = UDim2.new(1, -140, 1, -280) }, Enum.KeyCode.ButtonX)

-- THE SLIDE HAS NO KEY OF ITS OWN. It is the crouch, pressed while sprinting — MovementClient's
-- crouchPressed decides which you get, and everything else about the slide (on the ground, at speed, off
-- cooldown, stamina) is checked there and again on the server. This used to be a separate bind on C and
-- a separate touch button; both are gone. Nothing else should call MovementState.RequestSlide.
--
-- TOUCH BUTTON MAP (CAS positions, offsets from the bottom-right corner). Columns x -140 / -250 / -360 /
-- -470, rows y -180 / -280:
--   -140: FIRE (y -180), RELOAD (y -280)      -250: AIM (y -180), RUN (y -280)
--   -360: PET (y -180), CROUCH (y -280, MovementClient — and the slide, held with RUN)
--   -470: MOVE (y -280, MovementClient)
-- CAM is not in this grid: it is CombatClient's own button, top-right.
-- ContextActionService draws at most SEVEN touch buttons and silently blanks the eighth, so this grid is
-- full at seven. Adding one means taking one away. (SLIDE was the eighth until it was folded into
-- CROUCH.)

local SLOT_COUNT = 8

local function selectSlot(index)
	-- Predict the raise immediately, so a click in the gap before the server's loadout push
	-- arrives can't slip a phantom shot through.
	if loadout and loadout.equipped ~= index and loadout.slots[index] then
		localEquipReadyAt = os.clock() + MatchConfig.EquipTime
		equipRemote:FireServer(index)
	end
end

for index = 1, SLOT_COUNT do
	Settings.Bind("BRR_Slot" .. index, "Slot" .. index, function(_, inputState)
		if inputState == Enum.UserInputState.Begin and inCombat() then
			selectSlot(index)
		end
		return Enum.ContextActionResult.Pass
	end)
end

-- The next-slot key steps through the slots that have something in them.
--
-- Also on the right shoulder, because a controller has no number row: with this bound, every slot is
-- reachable by cycling, and without it a controller player could not change weapon at all for a whole
-- match. The numbered BRR_Slot1..N bindings below are deliberately left keyboard-only for the same
-- reason. R1 is free across the tree; L1 is the vehicle handbrake (VehicleClient:327), so binding
-- previous-slot there would fight a control while driving.
Settings.Bind("BRR_NextSlot", "NextSlot", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin or not inCombat() or not loadout or player:GetAttribute("MenuOpen") then
		return Enum.ContextActionResult.Pass
	end
	local current = loadout.equipped or 0
	for offset = 1, SLOT_COUNT do
		local index = (current - 1 + offset) % SLOT_COUNT + 1
		if loadout.slots[index] then
			selectSlot(index)
			break
		end
	end
	return Enum.ContextActionResult.Pass
end, nil, Enum.KeyCode.ButtonR1)

-- THE WHEEL IS THE HOTBAR, AND ZOOM IS A KEY (Z). It used to be the other way round.
--
-- Scroll down for the next item, up for the previous, skipping empty slots exactly as Q does — Q still
-- works, so nothing is lost for a keyboard or controller player.
local function cycleSlot(step)
	if not inCombat() or not loadout or player:GetAttribute("MenuOpen") then
		return
	end
	local current = loadout.equipped or 0
	for offset = 1, SLOT_COUNT do
		local index = (current - 1 + step * offset) % SLOT_COUNT + 1
		if loadout.slots[index] then
			selectSlot(index)
			return
		end
	end
end

-- Roblox's OWN camera zooms on the wheel too, and it isn't ours to have: without pinning it, one scroll
-- both switches your gun and pulls the camera out. Pinned only while the wheel belongs to the hotbar
-- (in combat) and handed straight back otherwise, so zooming still works in the lobby.
local defaultMinZoom, defaultMaxZoom = player.CameraMinZoomDistance, player.CameraMaxZoomDistance
local zoomPinned = nil
-- `pin` true pins, false hands the stock range back, and nil means SOMEONE ELSE OWNS THE RANGE: touch
-- nothing, and forget what we last did so the next real pin or release still writes rather than being
-- swallowed by the cache. The nil case is the vehicle camera (#60) -- "not pinned" is NOT the same as
-- "hands off", because releasing WRITES the stock 0.5..20 back, and that is what used to undo
-- VehicleClient's widened 6..55 one frame after the player sat down.
local function pinCameraZoom(pin)
	if pin == nil then
		zoomPinned = nil
		return
	end
	if zoomPinned == pin then
		return
	end
	zoomPinned = pin
	if pin then
		local at = math.clamp(zoomDistance, defaultMinZoom, defaultMaxZoom)
		player.CameraMaxZoomDistance = at
		player.CameraMinZoomDistance = at
	else
		player.CameraMinZoomDistance = defaultMinZoom
		player.CameraMaxZoomDistance = defaultMaxZoom
	end
end

RunService.Heartbeat:Connect(function()
	if player:GetAttribute("InVehicle") then
		pinCameraZoom(nil)
	else
		pinCameraZoom(inCombat())
	end
end)

UserInputService.InputChanged:Connect(function(input, processed)
	-- In a vehicle the wheel belongs to the camera: the zoom range is handed back there (#60), so
	-- leaving the hotbar on the wheel would zoom AND change gun on one scroll -- the exact double
	-- action this pin exists to prevent. The number keys still switch slots, and a driver cannot fire.
	if processed or input.UserInputType ~= Enum.UserInputType.MouseWheel or not inCombat()
		or player:GetAttribute("MenuOpen") or player:GetAttribute("InVehicle") then
		return
	end
	cycleSlot(input.Position.Z > 0 and -1 or 1)
end)

-- Z steps the camera OUT one notch and wraps: first person -> closest -> ... -> furthest -> first person.
-- A key can't scroll both ways, so it cycles; T still toggles first/third person outright. The step is
-- twice the wheel's old one, or the cycle takes seven presses to get round.
Settings.Bind("BRR_Zoom", "Zoom", function(_, inputState)
	-- Not while seated: the vehicle's own camera owns the distance there (#60), and re-pinning would
	-- clamp it back the moment Z was pressed.
	if inputState ~= Enum.UserInputState.Begin or not inCombat() or player:GetAttribute("MenuOpen")
		or player:GetAttribute("InVehicle") then
		return Enum.ContextActionResult.Pass
	end
	if not Settings.Get("ThirdPerson") then
		zoomDistance = ZOOM_MIN
		Settings.Set("ThirdPerson", true)
	elseif zoomDistance >= ZOOM_MAX then
		Settings.Set("ThirdPerson", false)
	else
		zoomDistance = math.min(ZOOM_MAX, zoomDistance + ZOOM_STEP * 2)
	end
	-- The pin holds the camera where the game's own third-person distance is, so it follows the step.
	zoomPinned = nil
	pinCameraZoom(inCombat())
	return Enum.ContextActionResult.Pass
end)

-- Your companion's move. Sends where you're aiming and the server picks the enemy nearest the
-- crosshair. Works in the lobby too, where it's a harmless demo on the practice targets.
local companionRemote = Remotes.Event("CompanionAbility")
Settings.Bind("BRR_Companion", "Companion", function(_, inputState)
	if inputState ~= Enum.UserInputState.Begin or spectating or player:GetAttribute("MenuOpen") then
		return Enum.ContextActionResult.Pass
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		companionRemote:FireServer(aimPoint())
	end
	return Enum.ContextActionResult.Pass
end, { title = "PET", position = UDim2.new(1, -360, 1, -180) }, Enum.KeyCode.ButtonY)

-- Launches (rockets, launch pads, blinks, the geyser) and the Rot Glider are handled in
-- StarterPlayerScripts/MovementClient, which also keeps a launch's speed through the air.

--------------------------------------------------------------------------------
-- Viewmodel
--
-- In first person your own gun is hidden (it's welded at chest height, right where the camera
-- sits), so a full-detail copy is built locally and drawn in front of the camera in gloved hands.
-- StarterPlayerScripts/Viewmodel builds it and does every animation from the gun's own animation
-- contract: the draw and the rack, each shot's mechanism, reloads by mechanism (a magazine swap, a
-- pistol's slide release, a revolver's crane and speedloader, a pump fed a shell at a time, a break
-- action, a lever, a belt-fed cover, a rocket down the muzzle), aiming down the gun's own sight line,
-- sprinting, inspecting, sway and bob. StarterPlayerScripts/GunFx throws the muzzle flash, the spent
-- cases, the dropped magazines and the tracer rounds. This section feeds them what the player is
-- doing, and shows the scope and the laser. Nothing here replicates.
--------------------------------------------------------------------------------

local GunFx = require(script.Parent:WaitForChild("GunFx"))

-- Each muzzle's report, by the kind of flash the gun makes.
local SHOT_CUE = {
	pistol = "GunshotPistol", revolver = "GunshotRevolver", smg = "GunshotSMG", rifle = "GunshotRifle",
	suppressed = "GunshotSuppressed", brake = "GunshotSniper", shotgun = "GunshotShotgun", rotary = "GunshotHeavy",
	cannon = "GunshotCannon", rocket = "GunshotRocket", launcher = "GunshotRocket", rail = "GunshotRail",
	bubble = "GunshotBubble", crossbow = "GunshotCrossbow",
	-- The creative guns. Each has its own report below, by weapon id; these are what any later gun
	-- borrowing the same flash kind would fire with.
	squeak = "GunshotSqueak", droplets = "GunshotSquirt", noodle = "GunshotNoodle", bassring = "GunshotBassDrop",
	gumball = "GunshotGumball", zap = "GunshotZap", disco = "GunshotDisco", snow = "GunshotSnow",
	lava = "GunshotLavaLamp",
	-- The workshop guns, borrowing the nearest stock report until they have their own (claude-3b's
	-- SoundConfig): a blower roars like a belt gun, a hose hisses like the bubble gun, a broom and a
	-- vacuum thump and whirr, a popper cracks like a cannon and a keyboard clacks like a rifle.
	leaves = "GunshotLMG", spray = "GunshotBubble", dust = "GunshotShotgun", confetti = "GunshotCannon",
	keycap = "GunshotRifle",
}
-- Guns whose report differs from the rest of their flash kind (claude-3b's sound design), by weapon id.
local SHOT_CUE_BY_ID = {
	CameloLMG = "GunshotLMG", ReceiptPrinterLMG = "GunshotLMG",
	GrassToucherDMR = "GunshotDMR", SigmaScout = "GunshotDMR", SixSevenMarksman = "GunshotDMR", TouchGrassScout = "GunshotDMR",
	-- The creative guns each have a report of their own.
	SqueakyDuckPopper = "GunshotSqueak", JuiceBoxSquirter = "GunshotSquirt", SpaghettiSlinger = "GunshotNoodle",
	BoomboxBassline = "GunshotBassDrop", GumballGatling = "GunshotGumball", FidgetDiscLauncher = "GunshotFidget",
	MicrowaveZapper = "GunshotZap", PizzaCutterCrossbow = "GunshotPizza", DiscoBallDeleter = "GunshotDisco",
	ToasterMortar = "GunshotToaster", RubberChickenRailgun = "GunshotChicken", LavaLampLancer = "GunshotLavaLamp",
	SnowGlobeSingularity = "GunshotSnow", GrandmasSlipperLauncher = "GunshotSlipper",
	-- The workshop guns: the vacuum whirrs rather than thumps, so it takes the heavy report instead of the
	-- broom's; the rest follow their flash kind above.
	DustDevilRotary = "GunshotHeavy",
}
-- What flies out of it.
local TRACER_KIND = {
	shotgun = "pellet", rotary = "heavy", cannon = "heavy", rail = "energy", bubble = "bubble", rocket = "rocket",
	launcher = "grenade", crossbow = "bolt",
	squeak = "squeak", droplets = "droplets", noodle = "noodle", bassring = "bassring", gumball = "gumball", zap = "zap",
	disco = "disco", snow = "snow", lava = "lava",
	leaves = "leaf", spray = "waterjet", confetti = "streamer", keycap = "keycap",
}

-- By gun, where the flash alone doesn't say: a broom and a vacuum both puff dust, but one throws bristles
-- and the other dust bunnies.
local TRACER_KIND_BY_ID = {
	CleanSweepDouble = "bristle", DustDevilRotary = "dustbunny",
}

-- { vm, source, key, id, scopedIn, laserBeam, laserDot }
local viewmodel = nil
local landDip = 0
-- How far the gun is dropped for a slide, a ledge climb or a vault (0..1), read each frame from
-- MovementState.dip, which MovementClient eases in and out with the move itself. (It used to be set
-- from the slide key before this local existed, which wrote a global, so the dip never reached the
-- viewmodel at all.)
local slideDip = 0
local wasReloading = false
-- Slots whose gun has already been drawn once ("slot:weaponId"): only the first draw racks it.
local drawn = {}

local localOnly = Viewmodel.LocalOnly

--------------------------------------------------------------------------------
-- Scope view
--------------------------------------------------------------------------------

local scopeGui = Instance.new("ScreenGui")
scopeGui.Name = "BRR_Scope"
scopeGui.IgnoreGuiInset = true
scopeGui.ResetOnSpawn = false
scopeGui.DisplayOrder = -1
scopeGui.Enabled = false
scopeGui.Parent = player:WaitForChild("PlayerGui")

-- A round lens filling most of the screen height, with everything outside it blacked out by a
-- stroke far thicker than any screen.
local scopeLens = Instance.new("Frame")
scopeLens.AnchorPoint = Vector2.new(0.5, 0.5)
scopeLens.Position = UDim2.fromScale(0.5, 0.5)
scopeLens.Size = UDim2.fromScale(0.92, 0.92)
scopeLens.SizeConstraint = Enum.SizeConstraint.RelativeYY
scopeLens.BackgroundColor3 = Color3.fromRGB(120, 200, 180)
scopeLens.BackgroundTransparency = 0.94
scopeLens.BorderSizePixel = 0
scopeLens.Parent = scopeGui

local lensCorner = Instance.new("UICorner")
lensCorner.CornerRadius = UDim.new(0.5, 0)
lensCorner.Parent = scopeLens

local lensStroke = Instance.new("UIStroke")
lensStroke.Thickness = 4000
lensStroke.Color = Color3.new(0, 0, 0)
-- Outside the lens, always. Drawn centred on the border, half of a 4000-pixel stroke lies inside the
-- lens and the scope is solid black. Pinned where the engine has the property.
pcall(function()
	lensStroke.BorderStrokePosition = Enum.BorderStrokePosition.Outer
end)
lensStroke.Parent = scopeLens

local function reticle(position, size, color)
	local line = Instance.new("Frame")
	line.AnchorPoint = Vector2.new(0.5, 0.5)
	line.Position = position
	line.Size = size
	line.BackgroundColor3 = color or Color3.new(0, 0, 0)
	line.BorderSizePixel = 0
	line.Parent = scopeLens
	return line
end

-- A duplex reticle: fine lines through the middle, heavy posts toward the edge, a red centre dot.
reticle(UDim2.fromScale(0.5, 0.5), UDim2.new(1, 0, 0, 1))
reticle(UDim2.fromScale(0.5, 0.5), UDim2.new(0, 1, 1, 0))
for _, side in ipairs({ -1, 1 }) do
	reticle(UDim2.fromScale(0.5 + side * 0.33, 0.5), UDim2.new(0.34, 0, 0, 4))
	reticle(UDim2.fromScale(0.5, 0.5 + side * 0.33), UDim2.new(0, 4, 0.34, 0))
end
reticle(UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(4, 4), Color3.fromRGB(255, 60, 60))

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

-- SightsUp tells the HUD the gun is at the eye, so it hides the crosshair over the sight picture.
local function setSightsUp(value)
	if player:GetAttribute("SightsUp") ~= value then
		player:SetAttribute("SightsUp", value)
	end
end

local function destroyViewmodel()
	if viewmodel then
		viewmodel.vm:Destroy()
		viewmodel = nil
	end
	scopeGui.Enabled = false
	setSightsUp(false)
end

-- The laser: a beam and a dot, shown only while aiming, built once per viewmodel.
local function laserParts(model)
	local beam = Instance.new("Part")
	beam.Name = "LaserBeam"
	beam.Size = Vector3.new(0.02, 0.02, 1)
	beam.Color = Color3.fromRGB(255, 40, 40)
	beam.Material = Enum.Material.Neon
	beam.Transparency = 1
	localOnly(beam)
	beam.Parent = model
	local dot = Instance.new("Part")
	dot.Name = "LaserDot"
	dot.Shape = Enum.PartType.Ball
	dot.Size = Vector3.new(0.12, 0.12, 0.12)
	dot.Color = Color3.fromRGB(255, 60, 60)
	dot.Material = Enum.Material.Neon
	dot.Transparency = 1
	localOnly(dot)
	dot.Parent = model
	return beam, dot
end

-- What the viewmodel's animation asks for as it plays: mechanism sounds, spent cases, a dropped
-- magazine.
local function onViewmodelEvent(kind, a, b)
	if kind == "sound" then
		Sfx.Play(a, 0.06)
	elseif kind == "casing" then
		GunFx.Casing(a, b)
	elseif kind == "drop" then
		GunFx.Drop(a, b)
	end
end

-- A spent case tinks on its first bounce, at most six a second however fast the gun fires; a shotgun
-- shell lands a lower, duller note.
do
	local recentTinks = {}
	GunFx.OnCasingLand = function(_, casing)
		local now = os.clock()
		while recentTinks[1] and now - recentTinks[1] > 1 do
			table.remove(recentTinks, 1)
		end
		if #recentTinks >= 6 then
			return
		end
		table.insert(recentTinks, now)
		Sfx.Play("CasingTink", 0.25, casing == "shell" and 0.7 or nil)
	end
end

-- The gun on your character says how it's dressed (WeaponService marks it), so the one in your hands
-- wears the same skin.
local function buildViewmodel(source, def, key)
	destroyViewmodel()
	local skinned = source:GetAttribute("Skinned") == true
	local color = skinned and source:GetAttribute("SkinColor") or Rarity.Color(def.rarity)
	local material = Enum.Material.Metal
	local materialName = source:GetAttribute("SkinMaterial")
	if skinned and type(materialName) == "string" then
		-- Indexing Enum.Material with a name it lacks throws rather than returning nil.
		local ok, value = pcall(function()
			return Enum.Material[materialName]
		end)
		if ok and value then
			material = value
		end
	end
	-- The gun is held in your own avatar's arms: the HeldGun's parent is your character.
	local vm = Viewmodel.new(def, { color = color, material = material, skinned = skinned, character = source.Parent, onEvent = onViewmodelEvent })
	viewmodel = { vm = vm, source = source, key = key, id = def.id, scopedIn = false }
	if vm.laserEmitter then
		viewmodel.laserBeam, viewmodel.laserDot = laserParts(vm.model)
	end
	-- Racked the first time this gun comes out of this slot; after that, just drawn.
	vm:Equip(not drawn[key])
	drawn[key] = true
	wasReloading = false
end

--------------------------------------------------------------------------------
-- Firing effects
--------------------------------------------------------------------------------

-- Your shot, on the gun in your hands: the kick and the mechanism (Viewmodel), and the flash out of
-- its muzzle (GunFx). The report and the tracer come with the server's ShotFired, below.
function kickViewmodel(def)
	if not viewmodel then
		return
	end
	local slot = loadout and loadout.equipped and loadout.slots[loadout.equipped]
	local roundsLeft = slot and math.max(0, (slot.mag or 1) - 1) or 0
	local vm = viewmodel.vm
	local muzzle = vm:Fire(roundsLeft)
	if muzzle and not viewmodel.scopedIn then
		GunFx.Flash(muzzle, vm.flash, 1, true)
	end
	if vm.action == "rocket" and vm.keys.Backblast and vm.frame then
		GunFx.Backblast(vm.frame * vm.keys.Backblast)
	end
end

local function viewmodelMuzzle()
	local vm = viewmodel and viewmodel.vm
	if not vm or not vm.model.Parent or viewmodel.scopedIn then
		return nil
	end
	local muzzle = vm:muzzleCFrame()
	return muzzle and muzzle.Position or nil
end

-- In third person the gun on the character is the one you can see, so shots leave its real muzzle.
local function heldGunMuzzle()
	if player.CameraMode == Enum.CameraMode.LockFirstPerson then
		return nil
	end
	local character = player.Character
	local gun = character and character:FindFirstChild("HeldGun")
	local receiver = gun and gun.PrimaryPart
	local attachment = receiver and receiver:FindFirstChild("Muzzle")
	return attachment and attachment.WorldPosition or nil
end

Settings.Bind("BRR_Inspect", "Inspect", function(_, inputState)
	if inputState == Enum.UserInputState.Begin and viewmodel and not aiming and not firing then
		viewmodel.vm:Inspect()
	end
	return Enum.ContextActionResult.Pass
end)

--------------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------------

-- The laser, while aiming: a beam from the emitter to the point under the crosshair, and a dot there.
-- Cast at the aim point rather than straight out of the emitter, whose axis sits below the sight
-- line, so the dot marks what the shot will actually hit.
local function updateLaser(result)
	local beam, dot = viewmodel.laserBeam, viewmodel.laserDot
	if not beam then
		return
	end
	if result.laser and result.aim > 0.35 and not viewmodel.scopedIn and not result.reloading then
		local origin = result.laser.Position
		local target = aimPoint() or origin + camera.CFrame.LookVector * 300
		local length = (target - origin).Magnitude
		beam.Size = Vector3.new(0.02, 0.02, length)
		beam.CFrame = CFrame.lookAt(origin:Lerp(target, 0.5), target)
		beam.Transparency = 0.35
		dot.Position = target
		dot.Transparency = 0
	else
		beam.Transparency = 1
		dot.Transparency = 1
	end
end

RunService:BindToRenderStep("BRR_Viewmodel", Enum.RenderPriority.Camera.Value + 2, function(delta)
	local dt = math.min(delta, 0.1)
	landDip -= landDip * math.clamp(dt * 8, 0, 1)
	slideDip = MovementState.dip

	local character = player.Character
	local source = character and character:FindFirstChild("HeldGun")
	local def = equippedDef()
	if not source or not def or not inCombat() or player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		destroyViewmodel()
		return
	end

	local slot = loadout.slots[loadout.equipped]
	local key = loadout.equipped .. ":" .. slot.id
	-- The same gun, still in hand, moved to another slot (the inventory panel rearranges the hotbar):
	-- no redraw and no lost reload. Its "drawn once" mark moves with it.
	if viewmodel and viewmodel.source == source and viewmodel.id == slot.id and viewmodel.key ~= key then
		drawn[key] = drawn[key] or drawn[viewmodel.key]
		viewmodel.key = key
	end
	if not viewmodel or viewmodel.key ~= key or viewmodel.source ~= source then
		buildViewmodel(source, def, key)
	end
	local vm = viewmodel.vm
	-- Only when it changes: the casings' raycast filter reads this list, and a new table every frame was
	-- a new filter every frame.
	if GunFx.IgnoreList[1] ~= character then
		GunFx.IgnoreList = { character }
	end

	-- A reload starts and stops on the server's word, so the clip always matches the real one.
	local reloading = loadout.reloading == true
	if reloading and not wasReloading then
		vm:StartReload(def.reloadTime or 1.5, slot.mag or 0, def.magSize or 1)
	elseif wasReloading and not reloading then
		vm:StopReload()
	end
	wasReloading = reloading

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local velocity = root and root.AssemblyLinearVelocity or Vector3.zero
	local result = vm:Update(dt, {
		camera = camera.CFrame,
		aiming = aiming,
		sprinting = sprinting,
		speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude,
		grounded = humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air,
		velocity = root and root.CFrame:VectorToObjectSpace(velocity) or Vector3.zero,
		mouseDelta = UserInputService:GetMouseDelta(),
		sway = Settings.Get("GunSway"),
		landDip = landDip,
		slideDip = slideDip,
	})

	setSightsUp(result.aim > 0.5 and not result.reloading)

	-- Scoped guns hand over to the full-screen scope once the gun is up to the eye.
	if result.scopedIn ~= viewmodel.scopedIn then
		viewmodel.scopedIn = result.scopedIn
		vm:SetHidden(result.scopedIn)
		scopeGui.Enabled = result.scopedIn
	end
	updateLaser(result)

	-- Parented once it has been posed, so it never flashes up at the character's chest.
	if not vm.model.Parent then
		vm.model.Parent = camera
	end
end)

local function watchLanding(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid then
		humanoid.StateChanged:Connect(function(_, newState)
			if newState == Enum.HumanoidStateType.Landed then
				landDip = 0.16
			end
		end)
	end
end

if player.Character then
	task.spawn(watchLanding, player.Character)
end
player.CharacterAdded:Connect(watchLanding)

--------------------------------------------------------------------------------
-- Item viewmodel
--
-- Heals, potions and movement items get a first-person model of their own, in the right hand:
-- raised on equip, bobbing with your stride, and animated while in use. Drinks are tipped up to
-- your mouth with a gulp every so often, a bandage is wound round with both hands, a med kit is
-- held open and worked on, boots are pulled on down low, and instant items punch forward as they
-- go off. Glowing parts pulse while a use is under way.
--------------------------------------------------------------------------------

local ITEM_HIP = Vector3.new(0.8, -0.85, -1.9)
local LEFT_REST = Vector3.new(-1.3, -2.8, -0.6)
local DRINKS = { MiniShield = true, ShieldPotion = true, SpeedSoda = true }
local TWO_HANDED = { Bandage = true, MedKit = true, BounceBoots = true }

local itemView = nil
local itemBob = 0
local useAlpha = 0
-- When the current use ends on our clock, and how long it lasts; set from each loadout push.
local useEndsAt, useDuration = nil, 1
local itemPunchAt = -math.huge

local function destroyItemView()
	if itemView then
		itemView.model:Destroy()
		itemView = nil
	end
end

local function buildItemView(slot, character)
	destroyItemView()
	local model = ItemModels.Build(slot.id, { name = "BRR_ItemViewmodel" })
	if not model then
		return
	end

	local pivot = model:GetPivot()
	local parts, offsets, glows = {}, {}, {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			localOnly(part)
			table.insert(parts, part)
			offsets[part] = pivot:ToObjectSpace(part.CFrame)
			if part.Name == "Glow" then
				table.insert(glows, part)
			end
		end
	end
	local gripPart = model:FindFirstChild("Grip")

	itemView = {
		model = model,
		key = nil,
		id = slot.id,
		parts = parts,
		offsets = offsets,
		glows = glows,
		grip = gripPart and offsets[gripPart].Position or Vector3.zero,
		arms = Viewmodel.Arms.new(model, character),
		startedAt = os.clock(),
	}
end

-- A palm frame from where it is, the way the fingers point and the way the back of the hand faces
-- (the same convention the gun keypoints use: -Z along the fingers, +Y out of the back of the hand).
local function handFrame(position, fingers, back)
	local z = -fingers.Unit
	local x = back.Unit:Cross(z).Unit
	return CFrame.fromMatrix(position, x, z:Cross(x).Unit, z)
end

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

RunService:BindToRenderStep("BRR_ItemViewmodel", Enum.RenderPriority.Camera.Value + 2, function(delta)
	local slot = equippedItemSlot()
	local character = player.Character
	if not slot or not character or not inCombat() or player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
		destroyItemView()
		return
	end

	local key = tostring(loadout.equipped) .. ":" .. slot.id
	if not itemView or itemView.key ~= key then
		buildItemView(slot, character)
		if not itemView then
			return
		end
		itemView.key = key
	end

	local dt = math.min(delta, 0.1)
	local now = os.clock()
	local id = itemView.id
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local velocity = root and root.AssemblyLinearVelocity or Vector3.zero
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local grounded = humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air

	local using = loadout.using ~= nil and loadout.using.index == loadout.equipped and useEndsAt ~= nil and now < useEndsAt
	local progress = using and math.clamp(1 - (useEndsAt - now) / math.max(useDuration, 0.05), 0, 1) or 0
	useAlpha += ((using and 1 or 0) - useAlpha) * math.clamp(dt * 10, 0, 1)

	-- Equip: up from below.
	local down = (1 - math.clamp((now - itemView.startedAt) / math.max(MatchConfig.EquipTime, 0.05), 0, 1)) ^ 3
	local equipOffset = CFrame.new(0, -1.1 * down, 0.3 * down) * CFrame.Angles(-0.9 * down, 0, 0.35 * down)

	-- Stride bob and breathing, calmer while using.
	local bobOffset = CFrame.identity
	if Settings.Get("GunSway") then
		if grounded and speed > 1 then
			itemBob += dt * speed * 0.55
		end
		local amplitude = (grounded and math.min(speed / 16, 1.5) or 0) * (1 - useAlpha * 0.6)
		bobOffset = CFrame.new(math.sin(itemBob) * 0.05 * amplitude,
			-math.abs(math.cos(itemBob)) * 0.07 * amplitude + math.sin(now * 1.6) * 0.012, 0)
			* CFrame.Angles(0, 0, math.sin(itemBob) * 0.03 * amplitude)
	end

	-- The use itself.
	local useTarget
	local leftExtra = Vector3.zero
	if DRINKS[id] then
		local tip = smooth(progress / 0.25)
		useTarget = CFrame.new(-0.6 * tip, 0.62 * tip + math.sin(now * 13) * 0.025 * tip, 1.05 * tip)
			* CFrame.Angles(1.15 * tip, 0, 0.35 * tip)
	elseif id == "Bandage" then
		local wind = now * 8
		useTarget = CFrame.new(-0.45 + math.cos(wind) * 0.08, 0.25 + math.sin(wind) * 0.06, 0.2) * CFrame.Angles(0, 0, wind * 0.5)
		leftExtra = Vector3.new(math.cos(wind * 1.5) * 0.25, math.sin(wind * 1.5) * 0.25, 0)
	elseif id == "MedKit" then
		useTarget = CFrame.new(-0.55, 0.15 + math.sin(now * 18) * 0.02, 0.15) * CFrame.Angles(-0.45, 0.1, math.sin(now * 9) * 0.05)
		leftExtra = Vector3.new(math.sin(now * 11) * 0.15, 0, math.cos(now * 11) * 0.1)
	elseif id == "BounceBoots" then
		useTarget = CFrame.new(-0.3, -0.7 + math.abs(math.sin(now * 10)) * 0.12, 0.2) * CFrame.Angles(-0.9, 0, 0)
	else
		useTarget = CFrame.new(0, 0.1, 0)
	end
	local useOffset = CFrame.identity:Lerp(useTarget, useAlpha)

	-- Instant items punch forward as they go off.
	local sincePunch = now - itemPunchAt
	local punch = sincePunch < 0.3 and math.sin(sincePunch / 0.3 * math.pi) or 0
	local punchOffset = CFrame.new(0, 0.15 * punch, -0.6 * punch) * CFrame.Angles(0.35 * punch, 0, 0)

	local view = camera.CFrame
	local frame = view * CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0)
		* equipOffset * bobOffset * useOffset * punchOffset * CFrame.new(-itemView.grip)

	local parts = table.create(#itemView.parts + 40)
	local cframes = table.create(#itemView.parts + 40)
	for index, part in ipairs(itemView.parts) do
		parts[index] = part
		cframes[index] = frame * itemView.offsets[part]
	end

	local pulse = using and (0.5 + 0.5 * math.sin(now * 12)) * 0.6 or 0
	for _, glow in ipairs(itemView.glows) do
		glow.LocalTransparencyModifier = pulse
	end

	-- The right hand wraps the item from its right side; the left hangs out of view below the screen
	-- until a two-handed use brings it up to the item, palm in.
	local right = frame * handFrame(itemView.grip + Vector3.new(0.14, -0.02, 0.06), Vector3.new(-0.3, 0.1, -1), Vector3.new(1, 0.1, 0.3))
	itemView.arms:pose(1, view, right, 0.85, parts, cframes)
	local rest = view * handFrame(LEFT_REST, Vector3.new(0.2, 0.1, -1), Vector3.new(-1, 0.2, 0))
	local left = rest
	if TWO_HANDED[id] and useAlpha > 0.02 then
		local side = frame * handFrame(itemView.grip + Vector3.new(-0.5, 0.3, -0.1) + leftExtra, Vector3.new(0.8, 0.3, -0.5), Vector3.new(-0.4, 1, 0))
		left = rest:Lerp(side, useAlpha)
	end
	itemView.arms:pose(-1, view, left, 0.4 + 0.4 * useAlpha, parts, cframes)
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	if not itemView.model.Parent then
		itemView.model.Parent = camera
	end
end)

--------------------------------------------------------------------------------
-- Shots
--
-- Tracers, flashes and impacts are GunFx's: a bullet is a short bright streak that takes real time
-- to arrive (a pellet spray, a heavy round, a bubble or a rocket per gun), and `onArrive` fires when
-- it lands, so the chip and the dust happen where and *when* it reaches the wall. The item-use burst
-- below is the only flash still drawn here.
--------------------------------------------------------------------------------

local function burst(position, color, size, range)
	local flash = Instance.new("Part")
	flash.Size = Vector3.new(size, size, size)
	flash.Shape = Enum.PartType.Ball
	flash.Position = position
	flash.Color = color
	flash.Material = Enum.Material.Neon
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Parent = effects

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = range
	light.Brightness = 3
	light.Parent = flash

	TweenService:Create(flash, TweenInfo.new(0.1), {
		Size = Vector3.new(0.2, 0.2, 0.2),
		Transparency = 1,
	}):Play()

	task.delay(0.14, function()
		flash:Destroy()
	end)
end

-- Bullet marks: a dark chip left on whatever a shot hit, fading after a while. The shot's own
-- line is cast again here, which is how the surface (and its normal) is known; bodies and
-- pickups don't get chips. Kept to a fixed number so a long fight never piles them up.
local MARK_LIMIT = 80
local MARK_LIFE = 14
local marks = {}
local markParams = RaycastParams.new()
markParams.FilterType = Enum.RaycastFilterType.Exclude

local function markImpact(origin, endPoint)
	local delta = endPoint - origin
	if delta.Magnitude < 1 then
		return
	end
	local filter = { effects }
	if player.Character then
		table.insert(filter, player.Character)
	end
	for _, name in ipairs({ "Loot", "Deployables" }) do
		local folder = workspace:FindFirstChild(name)
		if folder then
			table.insert(filter, folder)
		end
	end
	if viewmodel then
		table.insert(filter, viewmodel.vm.model)
	end
	markParams.FilterDescendantsInstances = filter

	local hit = workspace:Raycast(origin, delta.Unit * (delta.Magnitude + 0.6), markParams)
	if not hit then
		return
	end
	local instance = hit.Instance
	local model = instance:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end
	if instance:IsA("BasePart") and not instance:IsA("Terrain") and instance.Transparency >= 1 then
		return
	end

	local mark = Instance.new("Part")
	mark.Name = "BulletMark"
	mark.Size = Vector3.new(0.55, 0.55, 0.04)
	-- Its thin axis along the surface normal, a hair off the surface so the two never flicker.
	mark.CFrame = CFrame.lookAt(hit.Position + hit.Normal * 0.045, hit.Position + hit.Normal) * CFrame.Angles(0, 0, math.random() * math.pi * 2)
	mark.Color = Color3.fromRGB(30, 28, 26)
	mark.Material = Enum.Material.Slate
	mark.Transparency = 0.1
	mark.Anchored = true
	mark.CanCollide = false
	mark.CanQuery = false
	mark.CanTouch = false
	mark.CastShadow = false
	mark.Parent = effects

	table.insert(marks, mark)
	if #marks > MARK_LIMIT then
		local oldest = table.remove(marks, 1)
		if oldest.Parent then
			oldest:Destroy()
		end
	end
	task.delay(MARK_LIFE, function()
		if mark.Parent then
			TweenService:Create(mark, TweenInfo.new(1), { Transparency = 1 }):Play()
			task.wait(1)
			mark:Destroy()
		end
	end)
	return hit
end

-- Beyond this, other people's tracers and flashes aren't drawn. Each shot is several neon
-- parts with PointLights; with a full lobby of bots fighting across the map that was hundreds
-- of instances a second that nobody could see.
local EFFECT_CULL_DISTANCE = 450

-- The gun that fired. A player's is on their character. A bot's shot is broadcast from its head
-- with no shooter, so its character is whichever one has a head at that point.
local headQuery = OverlapParams.new()
headQuery.MaxParts = 12

local function shooterGun(shooter, origin)
	if typeof(shooter) == "Instance" and shooter:IsA("Player") then
		return shooter.Character and shooter.Character:FindFirstChild("HeldGun")
	end
	for _, part in ipairs(workspace:GetPartBoundsInRadius(origin, 0.75, headQuery)) do
		if part.Name == "Head" and part.Parent then
			local gun = part.Parent:FindFirstChild("HeldGun")
			if gun then
				return gun
			end
		end
	end
	return nil
end

local function gunMuzzle(gun)
	local receiver = gun and gun.PrimaryPart
	local attachment = receiver and receiver:FindFirstChild("Muzzle")
	return attachment and attachment.WorldCFrame or nil
end

shotFired.OnClientEvent:Connect(function(shooter, origin, endPoints, rarity)
	local mine = shooter == player
	local gun = shooterGun(shooter, origin)
	local flash = gun and gun:GetAttribute("Flash") or "rifle"
	local cue = SHOT_CUE_BY_ID[gun and gun:GetAttribute("WeaponId") or ""] or SHOT_CUE[flash] or "GunshotRifle"

	if mine then
		-- In first person the body — and the gun on it — sits below and beside the camera,
		-- so a tracer from the real muzzle looks like it leaves your hip at an odd angle.
		-- Start it at the viewmodel's muzzle instead (its flash went off with the kick), or just
		-- below-right of the view. In third person the real gun is in shot, so it leaves that.
		local view = camera.CFrame
		local muzzle = heldGunMuzzle() and gunMuzzle(gun)
		if muzzle then
			GunFx.Flash(muzzle, flash, 1, false)
		end
		origin = viewmodelMuzzle()
			or (muzzle and muzzle.Position)
			or view.Position + view.LookVector * 2.2 - view.UpVector * 0.7 + view.RightVector * 0.8
		Sfx.Play(cue, 0.08)
	else
		-- Everyone else's shots (bots included) come from where they were fired, so gunfire tells
		-- you where a fight is, and each gun sounds like what it is.
		Sfx.PlayAt(cue, origin, 0.08)

		-- Still drawn if either end is close: a far-off shooter hitting the wall next to you
		-- has to be visible.
		local eye = camera.CFrame.Position
		local near = (origin - eye).Magnitude < EFFECT_CULL_DISTANCE
		for _, endPoint in ipairs(endPoints) do
			if near then
				break
			end
			near = (endPoint - eye).Magnitude < EFFECT_CULL_DISTANCE
		end
		if not near then
			return
		end

		-- The flash and the tracer leave the gun they can see, when it's where the shot came from.
		local muzzle = gunMuzzle(gun)
		if muzzle and (muzzle.Position - origin).Magnitude < 10 then
			GunFx.Flash(muzzle, flash, 1, false)
			origin = muzzle.Position
		end
	end

	-- Bubbles pop without a trace, and water, snow, noodles, gumballs and squeaks don't chip a wall;
	-- rockets and grenades have their own explosion, so no chip either.
	local kind = TRACER_KIND_BY_ID[gun and gun:GetAttribute("WeaponId") or ""] or TRACER_KIND[flash] or "bullet"
	local chips = not ({ bubble = true, rocket = true, grenade = true, droplets = true, snow = true, noodle = true,
		gumball = true, squeak = true, leaf = true, waterjet = true, streamer = true, dustbunny = true })[kind]
	for _, endPoint in ipairs(endPoints) do
		GunFx.Tracer(origin, endPoint, kind, chips and function()
			local hit = markImpact(origin, endPoint)
			if hit then
				GunFx.Impact(hit.Position, hit.Normal)
			end
		end or nil)
	end
end)

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- Any exit from combat has to drop the zoom, or the camera stays at ADS FOV in the lobby.
-- Leaving a match drops what belongs to the GUN -- the trigger and the scope. It deliberately does
-- NOT drop the sprint: sprinting is movement, the lobby has infinite stamina on purpose (#15), and a
-- sprint that must end (respawn, death, sitting down, the menu opening) is ended by
-- MovementState.SprintOffRequested, which MovementClient fires for every one of those (:1069, :1072,
-- :1075, :1086). Dropping it here as well is what made Oliver re-press shift once a second in the
-- lobby (#82).
local function leaveCombatState()
	firing = false
	setAiming(false)
	updateCameraMode()
end

-- The rack pushes its loadout before RangeState. Refresh here too, so that
-- either event order enters first person and creates the viewmodel immediately.
rangeStateRemote.OnClientEvent:Connect(function(on)
	rangeActive = on == true
	if rangeActive then
		updateCameraMode()
	else
		leaveCombatState()
	end
end)

-- Opening the menu mid-match releases the mouse and drops any held fire/aim/sprint;
-- closing it restores first person.
player:GetAttributeChangedSignal("MenuOpen"):Connect(function()
	if player:GetAttribute("MenuOpen") then
		leaveCombatState()
	else
		updateCameraMode()
	end
end)

-- Guns held plus items carried. Empty slots arrive as `false`.
local function itemCount(l)
	local count = 0
	for index = 1, SLOT_COUNT do
		local slot = l.slots[index]
		if slot then
			count += slot.kind == "item" and slot.count or 1
		end
	end
	return count
end

-- Someone finished using an item: a sound where they are and a burst in the item's colour. Our own
-- use punches the viewmodel instead of flashing a ball of light inside the camera.
Remotes.Event("ItemUsed").OnClientEvent:Connect(function(character, itemId)
	local item = ItemData.Get(itemId)
	local root = typeof(character) == "Instance" and character:FindFirstChild("HumanoidRootPart")
	if not item or not root then
		return
	end
	if character == player.Character then
		itemPunchAt = os.clock()
		Sfx.Play("Pickup", 0.1, item.kind == "movement" and 0.8 or 1.5)
		return
	end
	if (root.Position - camera.CFrame.Position).Magnitude > EFFECT_CULL_DISTANCE then
		return
	end
	Sfx.PlayAt("Pickup", root.Position, 0.1)
	burst(root.Position, item.color, item.kind == "movement" and 4 or 2.6, 14)
end)

-- Guns whose viewmodel template has been asked for ahead of time (the cache itself lives in Viewmodel
-- and may evict; a repeat Preload of an evicted gun would just rebuild it, so this only stops asking twice).
local preloaded = {}

loadoutChanged.OnClientEvent:Connect(function(newLoadout)
	-- Pickup cue whenever something was added. Only against an existing loadout, so the fresh
	-- one handed out at match start doesn't ping; uses (count going down) stay silent.
	local previous = loadout
	if previous and newLoadout and itemCount(newLoadout) > itemCount(previous) then
		Sfx.Play("Pickup", 0.1)
	end

	loadout = newLoadout
	-- Build each carried gun's viewmodel template now, while it's being picked up, rather than on its
	-- first draw (Viewmodel.Preload; it had no caller, so every first draw built one and hitched). One
	-- gun per frame so a full loadout arriving at once doesn't hitch here instead. Unskinned only: a
	-- skin is read off the held gun at draw time, which isn't known yet.
	if newLoadout and type(newLoadout.slots) == "table" then
		local wanted = {}
		for _, slot in pairs(newLoadout.slots) do
			if type(slot) == "table" and slot.kind == "weapon" and slot.id then
				local def = WeaponData.Get(slot.id)
				if def and not preloaded[def.id] then
					preloaded[def.id] = true
					table.insert(wanted, def)
				end
			end
		end
		if #wanted > 0 then
			task.spawn(function()
				for _, def in ipairs(wanted) do
					task.wait()
					pcall(Viewmodel.Preload, def, Rarity.Color(def.rarity), Enum.Material.Metal, false)
				end
			end)
		end
	end
	if newLoadout and newLoadout.using then
		useEndsAt = os.clock() + newLoadout.using.remaining
		useDuration = newLoadout.using.duration
	else
		useEndsAt = nil
	end
	if not newLoadout then
		leaveCombatState()
	else
		-- Covers raises the client can't predict (pickup and supply-drop swaps). Only ever
		-- extends: the per-shot push carries 0, and letting that shorten a predicted raise
		-- would reopen the gap.
		localEquipReadyAt = math.max(localEquipReadyAt, os.clock() + (newLoadout.equipReadyIn or 0))
		updateCameraMode()
	end
end)

-- A match broadcast is a STATE SNAPSHOT, not an event: MatchService's lobby ticker sends one about
-- once a second in Waiting, Intermission and Countdown, and again on every ready toggle, join and
-- leave. Acting on each arrival ran leaveCombatState() once a second in the lobby, which turned a
-- HELD sprint off once a second -- and a held key sends no second Begin, so it stayed off until
-- Oliver released and pressed again (#82). It dropped a held aim the same way.
-- The decision now takes the state we already had, and lives in Shared/CombatState where
-- tools/combat_state_probe.lua runs a truth table over it against the rule it replaced.
matchChanged.OnClientEvent:Connect(function(state)
	local previous = matchState
	matchState = state.state
	if CombatState.ShouldLeaveCombat(previous, matchState, rangeActive) then
		leaveCombatState()
	else
		updateCameraMode()
	end
end)

player.CharacterAdded:Connect(function(character)
	leaveCombatState()
	local humanoid = character:WaitForChild("Humanoid", 10)
	updateCameraMode()
	if humanoid then
		humanoid.Died:Connect(leaveCombatState)
	end
end)

updateCameraMode()
