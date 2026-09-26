-- Task 08 proof: where the driver's gun aims after boarding a car from combat, with the mouse moved
-- off-centre onto a target. The gallery's plugin reads the BUILT place's own CombatClient and
-- VehicleWeaponClient sources, so a main build renders main's behaviour and a branch build the branch's.
--
--   python tools/linux/studio.py gallery -Gallery tools/vehicle_aim_gallery.lua -OutDir <folder>
--
-- Each view runs, off that source:
--   1. CombatClient's real setThirdPerson/updateCameraMode (cut out of the script and compiled as a
--      module) against a stand-in UserInputService: combat on foot (third or first person), a few
--      frames, then InVehicle set and updateCameraMode called by its listener, a few frames more. The
--      stand-in also runs Roblox's camera module's mouse logic (CameraUtils override/restore), as
--      tools/vehicle_aim_check.py does, because on main that restore re-locks a first-person rider.
--   2. VehicleWeaponClient's PURE aimMode/aimScreenPoint on the resulting MouseBehavior, with the
--      mouse on the target (the white ring), and the ray through that screen point from Studio's real
--      camera, past the car, as aimPoint casts it.
--   3. VehicleWeaponData.Solve for the driver's gun at that point; the gun is posed there and a red
--      beam drawn from its muzzle to where the shot lands. The red ring is the screen point the gun used.
-- What this cannot show: a live client. Studio's gallery and Run mode run no LocalScripts and move no
-- mouse, so the mouse position is set, not moved, and the chase camera is placed by hand.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))

local ORIGIN = Vector3.new(0, 420, 0)
local MODEL = "Rotster"
local CURSOR = { 0.74, 0.34 } -- the mouse, as a share of the viewport: up and right of the middle

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function sourceOf(name)
	local script = StarterPlayer.StarterPlayerScripts:FindFirstChild(name)
	return (string.gsub(script.Source, "\r\n", "\n"))
end

-- A plugin can't loadstring; it can require a ModuleScript it wrote.
local function compile(source)
	local module = Instance.new("ModuleScript")
	module.Name = "BRR_VehicleAimCut"
	module.Source = source
	return require(module)
end

local function cut(source, first, last)
	local from = string.find(source, first, 1, true)
	local to = from and string.find(source, last, from, true)
	assert(from and to, "cut: " .. first .. " .. " .. last .. " not found")
	return string.sub(source, from, to - 1)
end

-- CombatClient's camera code, walked through combat -> board. Returns the MouseBehavior at the end.
local function walk(thirdPerson)
	local combat = sourceOf("CombatClient")
	local block = cut(combat, "local function setThirdPerson(", "player:GetAttributeChangedSignal(\"InVehicle\")")
	local lock = string.match(combat, "local function updateThirdPersonCamera%(delta%).-\n(\tif not player:GetAttribute%(\"MenuOpen\"%) then\n\t\tUserInputService%.MouseBehavior = [^\n]*\n\tend\n)")
	assert(lock, "updateThirdPersonCamera's mouse lock not found")
	local make = compile([[
return function(W)
local player, UserInputService, RunService, camera = W.player, W.UserInputService, W.RunService, W.camera
local thirdPersonActive, aiming = false, false
local lookYaw, lookPitch, shoulderDistance = 0, 0, 0
local zoomDistance, THIRD_PERSON_AIM_DISTANCE, PITCH_LIMIT = 12, 6, math.rad(80)
local touchDelta, gamepadLook = Vector2.zero, Vector2.zero
local function inCombat() return W.combat end
local function wantsThirdPerson() return W.third end
local function updateThirdPersonCamera(delta)
]] .. lock .. "end\n" .. block .. "\nreturn updateCameraMode\nend\n")

	local attributes = {}
	local W = { combat = true, third = thirdPerson }
	W.player = {
		CameraMode = Enum.CameraMode.Classic,
		GetAttribute = function(_, name) return attributes[name] end,
	}
	W.UserInputService = { MouseBehavior = Enum.MouseBehavior.Default }
	W.camera = { CFrame = CFrame.new(), CameraType = Enum.CameraType.Custom }
	local bound = {}
	W.RunService = {
		BindToRenderStep = function(_, name, _, fn) bound[name] = fn end,
		UnbindFromRenderStep = function(_, name) bound[name] = nil end,
	}
	local UIS, player = W.UserInputService, W.player
	-- Roblox's camera module's mouse logic (see vehicle_aim_check.py's harness for the source it follows).
	local saved, lastOverride, controllerOn = Enum.MouseBehavior.Default, nil, false
	local function restore()
		if UIS.MouseBehavior == lastOverride then
			UIS.MouseBehavior = saved
		end
		lastOverride = nil
	end
	local function frames(n)
		for _ = 1, n do
			for _, fn in pairs(bound) do
				fn(1 / 60)
			end
			local on = W.camera.CameraType ~= Enum.CameraType.Scriptable
			if controllerOn and not on then
				restore()
			end
			controllerOn = on
			if on then
				if player.CameraMode == Enum.CameraMode.LockFirstPerson then
					if UIS.MouseBehavior ~= lastOverride then
						saved = UIS.MouseBehavior
					end
					UIS.MouseBehavior = Enum.MouseBehavior.LockCenter
					lastOverride = Enum.MouseBehavior.LockCenter
				else
					restore()
				end
			end
		end
	end
	local updateCameraMode = make(W)
	updateCameraMode()
	frames(5)
	local onFoot = UIS.MouseBehavior
	attributes.InVehicle = true
	updateCameraMode() -- the InVehicle listener
	frames(5)
	return onFoot, UIS.MouseBehavior
end

local function pure()
	local source = sourceOf("VehicleWeaponClient")
	local block = cut(source, "-- PURE BEGIN", "-- PURE END")
	return compile(block .. "\nreturn { aimMode = aimMode, aimScreenPoint = aimScreenPoint }\n")
end

local function stage(folder)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(400, 1, 400)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(96, 124, 84)
	floor.Material = Enum.Material.Grass
	floor.Parent = folder
	local wall = Instance.new("Part")
	wall.Anchored = true
	wall.Size = Vector3.new(260, 90, 2)
	wall.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 45, -110))
	wall.Color = Color3.fromRGB(200, 196, 186)
	wall.Material = Enum.Material.Concrete
	wall.Parent = folder
end

local function place(folder)
	local model = VehicleModels.Build(MODEL, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	return model
end

-- As vehicle_weapons_gallery.lua: moves what hangs off `pivot` by hand (no physics in edit mode).
local function subtree(model, pivot)
	local set = { [pivot] = true }
	local grew = true
	while grew do
		grew = false
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and not set[part] then
				for _, link in ipairs(part:GetChildren()) do
					local parent = (link:IsA("WeldConstraint") or link:IsA("Motor6D")) and link.Part0 or nil
					if parent and set[parent] and link.Part1 == part then
						set[part] = true
						grew = true
						break
					end
				end
			end
		end
	end
	return set
end

local function rotateAbout(set, pivotFrame, rotation)
	local move = pivotFrame * rotation * pivotFrame:Inverse()
	for part in pairs(set) do
		part.CFrame = move * part.CFrame
	end
end

local function ring(parent, x, y, size, colour, thickness)
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromOffset(x, y)
	frame.Size = UDim2.fromOffset(size, size)
	frame.BackgroundTransparency = 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = colour
	stroke.Thickness = thickness
	stroke.Parent = frame
	frame.Parent = parent
	return frame
end

local function label(parent, text, y, colour)
	local line = Instance.new("TextLabel")
	line.BackgroundColor3 = Color3.new(0, 0, 0)
	line.BackgroundTransparency = 0.35
	line.BorderSizePixel = 0
	line.Position = UDim2.fromOffset(8, y)
	line.Size = UDim2.new(1, -16, 0, 22)
	line.Font = Enum.Font.GothamBold
	line.TextSize = 15
	line.TextXAlignment = Enum.TextXAlignment.Left
	line.TextColor3 = colour or Color3.new(1, 1, 1)
	line.Text = "  " .. text
	line.Parent = parent
end

local function beam(folder, from, to, colour, width)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanQuery = false
	part.Material = Enum.Material.Neon
	part.Color = colour
	part.Size = Vector3.new(width, width, (to - from).Magnitude)
	part.CFrame = CFrame.lookAt((from + to) / 2, to)
	part.Parent = folder
end

local function mark(folder, at, colour, size)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Anchored = true
	ball.CanQuery = false
	ball.Material = Enum.Material.Neon
	ball.Color = colour
	ball.Size = Vector3.one * size
	ball.Position = at
	ball.Parent = folder
end

local overlay

local function scene(folder, camera, thirdPerson)
	if overlay then
		overlay:Destroy()
	end
	stage(folder)
	local model = place(folder)
	-- The chase camera, placed by hand: behind and above the car, as Roblox's VehicleCamera sits zoomed
	-- out, a little to the right so the driver's gun on the bonnet shows past the cab.
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(9, 13, 18), ORIGIN + Vector3.new(0, 4, -30))

	local onFoot, inCar = walk(thirdPerson)
	local P = pure()
	local viewport = camera.ViewportSize
	local mouseX, mouseY = CURSOR[1] * viewport.X, CURSOR[2] * viewport.Y
	local locked = inCar == Enum.MouseBehavior.LockCenter
	local mode = P.aimMode("MouseMovement", locked)
	local x, y = P.aimScreenPoint(mode, mouseX, mouseY, viewport.X, viewport.Y)

	-- The target sits where the mouse points (on the wall), so it is what the player is trying to hit.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local cursorRay = camera:ViewportPointToRay(mouseX, mouseY)
	local cursorHit = workspace:Raycast(cursorRay.Origin, cursorRay.Direction * 1000, params)
	if cursorHit then
		local target = Instance.new("Part")
		target.Anchored = true
		target.Shape = Enum.PartType.Cylinder
		target.Size = Vector3.new(0.4, 14, 14)
		target.Color = Color3.fromRGB(40, 70, 190)
		target.CFrame = CFrame.lookAt(cursorHit.Position + cursorHit.Normal * 0.3, cursorHit.Position + cursorHit.Normal)
			* CFrame.Angles(0, math.rad(90), 0)
		target.Parent = folder
		local bull = target:Clone()
		bull.Size = Vector3.new(0.5, 6, 6)
		bull.Color = Color3.fromRGB(250, 200, 30)
		bull.Parent = folder
	end
	-- aimPoint: the ray through the chosen screen point, past the car.
	local ray = camera:ViewportPointToRay(x, y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
	local aim = hit and hit.Position or ray.Origin + ray.Direction * 1000

	-- The driver's gun, turned onto the aim by the server's own solve (as VehicleWeaponClient does).
	local spec = VehicleWeaponData.ForModel(MODEL, "driver")
	local names = VehicleWeaponData.Parts.driver
	local yawPart, pitchPart, muzzle = model:FindFirstChild(names.yaw), model:FindFirstChild(names.pitch), model:FindFirstChild(names.muzzle)
	local joint = yawPart:FindFirstChild("Joint")
	local rest = joint and joint.Part0 and joint.Part0.CFrame * joint.C0 or yawPart.CFrame
	local pitchJoint = pitchPart:FindFirstChild("Joint")
	local pivot = pitchJoint and pitchJoint.C0.Position or rest:PointToObjectSpace(pitchPart.Position)
	local mouth = pitchPart.CFrame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
	local yaw, pitch = VehicleWeaponData.Solve(spec, rest, pivot, mouth, aim)
	if yaw then
		rotateAbout(subtree(model, pitchPart), pitchPart.CFrame, CFrame.Angles(pitch, 0, 0))
		rotateAbout(subtree(model, yawPart), yawPart.CFrame, CFrame.Angles(0, yaw, 0))
	end
	beam(folder, muzzle.Position, aim, Color3.fromRGB(255, 40, 40), 0.5)
	mark(folder, aim, Color3.fromRGB(255, 40, 40), 4)

	overlay = Instance.new("ScreenGui")
	overlay.Name = "BRR_VehicleAimOverlay"
	overlay.IgnoreGuiInset = true
	overlay.DisplayOrder = 99999
	-- The mouse (white): where the player moved it. With LockCenter the real cursor is hidden and held in
	-- the middle, so this ring is where they are trying to put it.
	ring(overlay, mouseX, mouseY, 36, Color3.new(0, 0, 0), 7)
	ring(overlay, mouseX, mouseY, 36, Color3.new(1, 1, 1), 3)
	-- Where the gun aims (red): aimScreenPoint's answer, the point the ray above went through.
	ring(overlay, x, y, 18, Color3.fromRGB(255, 40, 40), 4)
	local cross = Instance.new("Frame")
	cross.AnchorPoint = Vector2.new(0.5, 0.5)
	cross.Position = UDim2.fromOffset(viewport.X / 2, viewport.Y / 2)
	cross.Size = UDim2.fromOffset(6, 6)
	cross.BackgroundColor3 = Color3.fromRGB(255, 220, 0)
	cross.BorderSizePixel = 0
	cross.Parent = overlay
	local view = thirdPerson and "third" or "first"
	label(overlay, string.format("boarded from %s-person combat: MouseBehavior %s on foot -> %s in the car",
		view, onFoot.Name, inCar.Name), 8)
	local good = mode == "mouse"
	label(overlay, string.format("driver's gun aims through the %s (%d, %d); mouse at (%d, %d)",
		good and "CURSOR" or "MIDDLE", x, y, mouseX, mouseY), 32,
		good and Color3.fromRGB(120, 255, 120) or Color3.fromRGB(255, 110, 110))
	label(overlay, "white ring = the mouse   red ring + beam = where the gun aims   yellow = screen middle", 56)
	overlay.Parent = game:GetService("CoreGui")
	note(string.format("%s: on foot %s, in the car %s, aim mode %s, gun through (%d,%d), mouse (%d,%d), viewport %dx%d",
		view, onFoot.Name, inCar.Name, mode, x, y, mouseX, mouseY, viewport.X, viewport.Y))
end

return {
	{ name = "third_person_board", settle = 1, setup = function(folder, camera) scene(folder, camera, true) end },
	{ name = "first_person_board", settle = 1, setup = function(folder, camera) scene(folder, camera, false) end },
}
