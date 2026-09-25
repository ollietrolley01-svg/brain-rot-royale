-- The mountable guns on every client (ServerScriptService's MountedGuns runs them; VehicleWeaponClient and
-- GunnerView give the gunner the trigger, the aim, first-person arms and the sight, as on a vehicle's
-- turret). This adds what an emplacement has and a vehicle does not:
--
--   THE GUNNER, AS OTHERS SEE THEM   posed standing at the grips (VehicleModels.Poses.GunnerStand), their
--       body turned with the gun about its traverse axis and leaning with its elevation. Getting on is a
--       0.35 s blend from where they stood to the grips, not a jump.
--   FIRING   each shot (the gun's WeaponFiredAt attribute changing) slams the barrel back on BarrelRecoil,
--       racks the charging handle on BoltSlide, steps the belt into the feed tray on BeltFeed and throws a
--       spent casing (or a link) out of the ejection port. The flash and the tracer are CombatClient's, from
--       the ShotFired broadcast at the muzzle.
--   HEAT     the HMG's barrel and jacket glow from dull to orange as the belt runs down, and steam off it
--       while it is overheated or cooling; a gun that is reloading shakes its belt through a belt change.
--   SUPPRESSION   a mounted gun's bullets passing close to this player's head blur and grey the screen
--       for a moment (never their own).
--   THE GUNNER'S HUD   an arc gauge under the sight (where the gun points inside its traverse and elevation
--       limits, which it eases into rather than hits: GunnerView.Pure.follow), the cannon's range to where
--       its grenade comes down, and the way off. The ammo readout ("N / infinity") is VehicleWeaponClient's.

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local MountedGunData = require(Shared:WaitForChild("MountedGunData"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local GunnerView = nil
do
	local ok, module = pcall(function()
		return require(script.Parent:WaitForChild("GunnerView", 5))
	end)
	GunnerView = ok and type(module) == "table" and module or nil
end

local TAG = MountedGunData.Tag
-- The turret's attribute names (VehicleWeapons publishes the belt, the last shot and the heat under them).
local ATTR = VehicleWeaponData.Attributes.turret
local POSE_DISTANCE = 160
local FX_DISTANCE = 180
local BLEND_TIME = 0.35
local HOT = Color3.fromRGB(255, 118, 40)

-- PURE BEGIN
local Pure = {}
-- How far a heat share (0 cold .. 1 run dry) takes a barrel toward glowing: nothing under half a belt.
function Pure.glow(heat, hot)
	if hot then
		return 1
	end
	return math.clamp((heat - 0.5) * 2, 0, 1)
end
-- The shortest distance from point p to the segment a-b (tables or Vector3s with X/Y/Z).
function Pure.segmentDistance(p, a, b)
	local abx, aby, abz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local apx, apy, apz = p.X - a.X, p.Y - a.Y, p.Z - a.Z
	local len2 = abx * abx + aby * aby + abz * abz
	local t = len2 > 0 and math.clamp((apx * abx + apy * aby + apz * abz) / len2, 0, 1) or 0
	local dx, dy, dz = apx - abx * t, apy - aby * t, apz - abz * t
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end
-- Suppression strength (0..1) of a round passing `miss` studs from the head.
function Pure.suppression(miss)
	return math.clamp(1 - (miss - 1.5) / 5, 0, 1)
end
-- PURE END

--------------------------------------------------------------------------------
-- Per-gun state
--------------------------------------------------------------------------------

local guns = {} -- model -> state; STRONG keys, dropped when the tag goes

local function jointOf(model, name)
	local pivot = model:FindFirstChild(name)
	local joint = pivot and pivot:FindFirstChild("Joint")
	return joint and joint:IsA("Motor6D") and joint or nil
end

local function stateOf(model)
	local s = guns[model]
	if s then
		return s
	end
	local kind = model:GetAttribute("MountedGun")
	local spec = kind and MountedGunData.SpecOf(kind)
	if not spec then
		return nil
	end
	s = { model = model, spec = spec, kind = kind, recoil = 0, recoilV = 0, bolt = 0, belt = 0, firedAt = model:GetAttribute(ATTR.firedAt) or 0,
		heatParts = {}, glow = -1 }
	for name in string.gmatch(model:GetAttribute("HeatParts") or "", "[^,]+") do
		local part = model:FindFirstChild(name)
		if part then
			table.insert(s.heatParts, { part = part, color = part.Color, material = part.Material })
		end
	end
	guns[model] = s
	return s
end

CollectionService:GetInstanceRemovedSignal(TAG):Connect(function(model)
	local s = guns[model]
	if s and s.steam then
		s.steam:Destroy()
	end
	guns[model] = nil
end)

--------------------------------------------------------------------------------
-- Firing: recoil, bolt, belt, casings
--------------------------------------------------------------------------------

local function ejectCasing(model, s)
	local pitch = model:FindFirstChild("TurretPitch")
	local port = pitch and pitch:FindFirstChild("EjectPoint")
	if not port then
		return
	end
	local frame = port.WorldCFrame
	local cannon = s.kind == "cannon"
	local casing = Instance.new("Part")
	casing.Name = "MountedGunCasing"
	casing.Shape = Enum.PartType.Cylinder
	casing.Size = cannon and Vector3.new(0.3, 0.16, 0.16) or Vector3.new(0.22, 0.08, 0.08)
	casing.Color = Color3.fromRGB(206, 164, 82)
	casing.Material = Enum.Material.Metal
	casing.Reflectance = 0.2
	casing.CanCollide = false
	casing.CanQuery = false
	casing.CanTouch = false
	casing.CFrame = frame * CFrame.Angles(0, math.rad(90), 0)
	local right = frame.RightVector
	casing.AssemblyLinearVelocity = right * (7 + math.random() * 3) + frame.UpVector * (5 + math.random() * 2)
	casing.AssemblyAngularVelocity = Vector3.new(math.random() * 20, math.random() * 20, math.random() * 20)
	casing.Parent = workspace:FindFirstChild("Effects") or workspace
	Debris:AddItem(casing, 1.4)
	-- Every other round of the HMG, a link off the belt too.
	if not cannon and s.shots % 2 == 0 then
		local link = casing:Clone()
		link.Shape = Enum.PartType.Block
		link.Size = Vector3.new(0.12, 0.03, 0.08)
		link.Color = Color3.fromRGB(40, 42, 46)
		link.AssemblyLinearVelocity = right * 5 + frame.UpVector * 3
		link.Parent = casing.Parent
		Debris:AddItem(link, 1.2)
	end
end

local function onShot(model, s)
	s.shots = (s.shots or 0) + 1
	s.recoilV += s.kind == "cannon" and -9 or -5
	s.bolt = 1
	s.belt = 1
	if (camera.CFrame.Position - model:GetPivot().Position).Magnitude < FX_DISTANCE then
		ejectCasing(model, s)
	end
end

--------------------------------------------------------------------------------
-- Heat
--------------------------------------------------------------------------------

local function steamFor(model, s)
	if s.steam then
		return s.steam
	end
	local pitch = model:FindFirstChild("TurretPitch")
	local at = pitch and pitch:FindFirstChild("SteamPoint")
	if not at then
		return nil
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "MountedGunSteam"
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(230, 230, 236))
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) })
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.6) })
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Speed = NumberRange.new(2, 3.5)
	emitter.SpreadAngle = Vector2.new(15, 15)
	emitter.Acceleration = Vector3.new(0, 3, 0)
	emitter.Rate = 0
	emitter.Parent = at
	s.steam = emitter
	return emitter
end

local function heatOf(s, now)
	local spec = s.spec
	local model = s.model
	local ammo = VehicleWeaponData.AmmoAt(spec, model:GetAttribute(ATTR.ammo) or spec.magazine, model:GetAttribute(ATTR.firedAt), now)
	local hot = model:GetAttribute(ATTR.hot) == true
	local ready = VehicleWeaponData.Ready(spec, ammo, hot)
	return math.clamp(1 - ammo / spec.magazine, 0, 1), hot, ready
end

local function showHeat(s, now)
	local heat, hot, ready = heatOf(s, now)
	s.ready = ready
	local glow = s.spec.overheat and Pure.glow(heat, hot) or 0
	glow = math.floor(glow * 20 + 0.5) / 20
	if glow ~= s.glow then
		s.glow = glow
		for _, h in ipairs(s.heatParts) do
			h.part.Color = h.color:Lerp(HOT, glow * 0.85)
			h.part.Material = glow > 0.6 and Enum.Material.Neon or h.material
		end
	end
	local steam = (hot or glow > 0.4) and steamFor(s.model, s)
	if s.steam then
		s.steam.Rate = steam and (hot and 26 or 10) or 0
	end
end

--------------------------------------------------------------------------------
-- The gunner, seen from outside
--------------------------------------------------------------------------------

local jointsOf = setmetatable({}, { __mode = "k" })
local function jointsFor(character)
	local joints = jointsOf[character]
	if not joints then
		joints = {}
		for _, d in ipairs(character:GetDescendants()) do
			if d:IsA("Motor6D") then
				joints[d.Name] = d
			end
		end
		jointsOf[character] = joints
	end
	return joints
end

-- Where each nearby character's root stood a moment ago, so getting on blends from there.
local lastRoot = setmetatable({}, { __mode = "k" })
local blends = setmetatable({}, { __mode = "k" }) -- character -> { from = CFrame, at = clock }

local function poseGunner(model, s, dt)
	local seat = model:FindFirstChild("GunnerSeat")
	local occupant = seat and seat.Occupant
	local character = occupant and occupant.Parent
	if not character then
		s.rider = nil
		return
	end
	local joints = jointsFor(character)
	local pose = VehicleModels.Poses.GunnerStand
	for name, transform in pairs(pose) do
		local joint = joints[name]
		if joint and joint.Parent then
			joint.Transform = transform
		end
	end
	local yawJoint, pitchJoint = jointOf(model, "TurretYaw"), jointOf(model, "TurretPitch")
	local root = joints.Root or joints.RootJoint
	if not (yawJoint and pitchJoint and root and root.Part0 and root.Parent) then
		return
	end
	-- The body turned with the gun about its traverse axis, and swung a little with its elevation about the
	-- trunnions (the eye rides the pitch pivot, the body leans after it).
	local restYaw = yawJoint.Part0.CFrame * yawJoint.C0
	local turn = restYaw * yawJoint.Transform * restYaw:Inverse()
	local restPitch = restYaw * yawJoint.Transform * pitchJoint.C0
	local pitchAngle = pitchJoint.Transform:ToEulerAnglesXYZ()
	local lean = restPitch * CFrame.Angles(pitchAngle * 0.45, 0, 0) * restPitch:Inverse()
	local want = lean * turn
	-- Getting on: from where they stood to the grips.
	if s.rider ~= character then
		s.rider = character
		local before = lastRoot[character]
		if before then
			blends[character] = { from = before, at = os.clock() }
		end
	end
	local frame = root.Part0.CFrame * root.C0
	local blend = blends[character]
	if blend then
		local t = (os.clock() - blend.at) / BLEND_TIME
		if t >= 1 then
			blends[character] = nil
		else
			t = t * t * (3 - 2 * t)
			local seated = want * root.Part0.CFrame
			local shown = blend.from:Lerp(seated, t)
			want = shown * root.Part0.CFrame:Inverse()
		end
	end
	root.Transform = frame:Inverse() * want * frame
	-- While the gun is reloading or cooling, the right arm goes to the can.
	if s.ready == false then
		local shoulder = joints.RightShoulder
		if shoulder then
			shoulder.Transform = CFrame.Angles(math.rad(40), 0, math.rad(35)) * CFrame.Angles(0, 0, math.sin(os.clock() * 7) * 0.15)
		end
	end
end

--------------------------------------------------------------------------------
-- Suppression
--------------------------------------------------------------------------------

local blur = Instance.new("BlurEffect")
blur.Name = "MountedGunSuppression"
blur.Size = 0
blur.Enabled = false
blur.Parent = Lighting
local grade = Instance.new("ColorCorrectionEffect")
grade.Name = "MountedGunSuppressionGrade"
grade.Enabled = false
grade.Parent = Lighting
local suppressed = 0

local function muzzleNear(origin)
	for model in pairs(guns) do
		local muzzle = model.Parent and model:FindFirstChild("TurretMuzzle")
		if muzzle and (muzzle.Position - origin).Magnitude < 4 then
			return model
		end
	end
	return nil
end

Remotes.Event("ShotFired").OnClientEvent:Connect(function(_shooter, origin, endPoints, _rarity, segment)
	if segment or typeof(origin) ~= "Vector3" or type(endPoints) ~= "table" then
		return
	end
	local model = muzzleNear(origin)
	if not model then
		return
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local seat = model:FindFirstChild("GunnerSeat")
	if head and not (seat and seat.Occupant and seat.Occupant.Parent == character) then
		for _, point in ipairs(endPoints) do
			if typeof(point) == "Vector3" then
				local miss = Pure.segmentDistance(head.Position, origin, point)
				suppressed = math.max(suppressed, Pure.suppression(miss))
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- The gunner's HUD
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "MountedGunHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Enabled = false
gui.DisplayOrder = 4
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.AnchorPoint = Vector2.new(0.5, 1)
panel.Position = UDim2.new(0.5, 0, 1, -96)
panel.Size = UDim2.fromOffset(240, 46)
panel.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
panel.BackgroundTransparency = 0.35
panel.BorderSizePixel = 0
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 8)

local function bar(y)
	local back = Instance.new("Frame")
	back.Position = UDim2.fromOffset(12, y)
	back.Size = UDim2.new(1, -24, 0, 4)
	back.BackgroundColor3 = Color3.fromRGB(70, 74, 84)
	back.BorderSizePixel = 0
	back.Parent = panel
	for _, x in ipairs({ 0, 1 }) do
		local stop = Instance.new("Frame")
		stop.AnchorPoint = Vector2.new(x, 0.5)
		stop.Position = UDim2.fromScale(x, 0.5)
		stop.Size = UDim2.fromOffset(2, 10)
		stop.BackgroundColor3 = Color3.fromRGB(255, 196, 64)
		stop.BorderSizePixel = 0
		stop.Parent = back
	end
	local mark = Instance.new("Frame")
	mark.AnchorPoint = Vector2.new(0.5, 0.5)
	mark.Size = UDim2.fromOffset(6, 10)
	mark.BackgroundColor3 = Color3.fromRGB(245, 245, 250)
	mark.BorderSizePixel = 0
	mark.Parent = back
	return mark
end
local yawMark = bar(10)
local pitchMark = bar(22)
local info = Instance.new("TextLabel")
info.BackgroundTransparency = 1
info.Position = UDim2.fromOffset(12, 28)
info.Size = UDim2.new(1, -24, 0, 16)
info.Font = Enum.Font.GothamBold
info.TextSize = 11
info.TextColor3 = Color3.fromRGB(190, 196, 208)
info.TextXAlignment = Enum.TextXAlignment.Left
info.Parent = panel

local function rangeOf(model, spec, yawDeg, pitchDeg)
	if spec.kind ~= "round" or not GunnerView or not GunnerView.Pure then
		return nil
	end
	local yawJoint, pitchJoint = jointOf(model, "TurretYaw"), jointOf(model, "TurretPitch")
	local muzzle = model:FindFirstChild("TurretMuzzle")
	local pitchPart = model:FindFirstChild("TurretPitch")
	if not (yawJoint and pitchJoint and muzzle and pitchPart) then
		return nil
	end
	local rest = yawJoint.Part0.CFrame * yawJoint.C0
	local mouth = pitchPart.CFrame:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
	local origin, direction = GunnerView.Pure.barrel(rest, pitchJoint.C0.Position, mouth, yawDeg, pitchDeg)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model, player.Character }
	local round = Ballistics.Rounds[spec.projectile]
	local impact = GunnerView.Pure.impact(spec, round, origin, direction, workspace.Gravity, function(from, to)
		local hit = workspace:Raycast(from, to - from, params)
		return hit and hit.Position or nil
	end, 0.05)
	return (impact - origin).Magnitude
end

local function showHud(model, s)
	local spec = s.spec
	local yawJoint, pitchJoint = jointOf(model, "TurretYaw"), jointOf(model, "TurretPitch")
	if not yawJoint or not pitchJoint then
		gui.Enabled = false
		return
	end
	local _, yaw = yawJoint.Transform:ToEulerAnglesYXZ()
	local pitch = pitchJoint.Transform:ToEulerAnglesXYZ()
	local yawDeg, pitchDeg = math.deg(yaw), math.deg(pitch)
	-- Yaw is positive to the left: the gauge reads left to right as the view does.
	yawMark.Position = UDim2.fromScale(math.clamp(0.5 - yawDeg / (2 * spec.yawLimit), 0, 1), 0.5)
	pitchMark.Position = UDim2.fromScale(math.clamp((pitchDeg - spec.pitchMin) / (spec.pitchMax - spec.pitchMin), 0, 1), 0.5)
	local atLimit = math.abs(yawDeg) > spec.yawLimit - 1.5
	yawMark.BackgroundColor3 = atLimit and Color3.fromRGB(255, 150, 80) or Color3.fromRGB(245, 245, 250)
	local text = string.format("TRAVERSE %+d\u{00B0}  ELEV %+d\u{00B0}", math.floor(-yawDeg + 0.5), math.floor(pitchDeg + 0.5))
	local range = rangeOf(model, spec, yawDeg, pitchDeg)
	if range then
		text ..= string.format("   RNG %d", math.floor(range / 5 + 0.5) * 5)
	end
	info.Text = text .. "   [SPACE] OFF"
	gui.Enabled = true
end

--------------------------------------------------------------------------------
-- Loop
--------------------------------------------------------------------------------

local sampleAt = 0
RunService.Stepped:Connect(function(_, dt)
	local now = workspace:GetServerTimeNow()
	local focus = camera.CFrame.Position
	local mine = nil
	for _, model in ipairs(CollectionService:GetTagged(TAG)) do
		local s = model.Parent and stateOf(model)
		if s then
			local near = (model:GetPivot().Position - focus).Magnitude < POSE_DISTANCE
			local firedAt = model:GetAttribute(ATTR.firedAt) or 0
			if firedAt ~= s.firedAt then
				s.firedAt = firedAt
				if near and firedAt > 0 then
					onShot(model, s)
				end
			end
			if near then
				-- The recoil slide springs back, the bolt and the belt settle.
				s.recoil, s.recoilV = s.recoil + s.recoilV * dt, s.recoilV + (-420 * s.recoil - 34 * s.recoilV) * dt
				s.bolt = math.max(0, s.bolt - dt * 9)
				s.belt = math.max(0, s.belt - dt * 12)
				local recoil = jointOf(model, "BarrelRecoil")
				if recoil then
					-- s.recoil runs negative on a shot: the barrel slides back (+Z) and springs home.
					recoil.Transform = CFrame.new(0, 0, -math.clamp(s.recoil, -0.3, 0.05))
				end
				local bolt = jointOf(model, "BoltSlide")
				if bolt then
					bolt.Transform = CFrame.new(0, 0, math.sin(s.bolt * math.pi) * 0.22)
				end
				local belt = jointOf(model, "BeltFeed")
				if belt then
					local change = s.ready == false and math.sin(os.clock() * 9) * 0.04 or 0
					belt.Transform = CFrame.new(s.belt * 0.05 + change, change * 0.5, 0)
				end
				showHeat(s, now)
				poseGunner(model, s, dt)
			end
			local seat = model:FindFirstChild("GunnerSeat")
			if seat and seat.Occupant and seat.Occupant.Parent == player.Character then
				mine = model
			end
		end
	end
	if mine then
		showHud(mine, guns[mine])
	else
		gui.Enabled = false
	end
	-- Where characters near a gun stand, sampled a few times a second, for the mount blend.
	sampleAt += dt
	if sampleAt > 0.08 then
		sampleAt = 0
		for _, other in ipairs(Players:GetPlayers()) do
			local character = other.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and humanoid and not humanoid.SeatPart then
				lastRoot[character] = root.CFrame
			end
		end
	end
	-- Suppression fades.
	if suppressed > 0.01 then
		blur.Enabled, grade.Enabled = true, true
		blur.Size = 14 * suppressed
		grade.Saturation = -0.6 * suppressed
		grade.Contrast = 0.1 * suppressed
		suppressed = math.max(0, suppressed - dt * 1.6)
	elseif blur.Enabled then
		blur.Enabled, grade.Enabled = false, false
		suppressed = 0
	end
end)
