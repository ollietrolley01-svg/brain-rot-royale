-- The mountable guns in Studio (tools/gallery.ps1 -Gallery tools/mounted_guns_gallery.lua -PlaceFile <copy>).
--
--   <kind>_a/_b/_c         each kind from three angles
--   <kind>_fp_hip/_ads     the gunner's first-person view through GunnerView (the real module, noInput):
--                          arms on the grips, the hip view through the shield's window, aimed down the sight;
--                          a note says whether the sight's ring and the server's shot line agree
--   <kind>_fire            a firing frame: the recoil slide back, a flash at the muzzle, casings and links in
--                          the air (posed as MountedGunClient throws them)
--   hmg_overheat           the barrel glowing and steaming, the belt run dry
--   mount_1..3             getting on: behind the gun, half way through the blend, at the grips
--   <kind>_3p              a gunner as everyone else sees them
--   sweep                  GunnerView turning the gun on a hard flick: its yaw every frame, noted
--   map_emplacement        a real map built (MapGenerator), MountedGunPlacement choosing its spots, each
--                          chosen spot noted with what it covers, and the view from behind the best one

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MountedGunModels = require(Shared:WaitForChild("MountedGunModels"))
local MountedGunData = require(Shared:WaitForChild("MountedGunData"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local GunnerView = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("GunnerView"))
local MountRig = require(Shared:WaitForChild("MountRig"))
-- A list of view-name prefixes renders just those views (e.g. { "veh_" }); nil renders them all.
local ONLY = nil
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local ORIGIN = Vector3.new(0, 420, 0)
local DT = 1 / 60
local SEAT_ROOT = CFrame.new(0, 0.15 + 1.486, 0)

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, size, frame, color, material)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = frame
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Parent = folder
	return part
end

local function stage(folder)
	block(folder, Vector3.new(700, 1, 700), CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0)), Color3.fromRGB(116, 128, 92), Enum.Material.Grass)
	block(folder, Vector3.new(160, 30, 2), CFrame.new(ORIGIN + Vector3.new(0, 15, -90)), Color3.fromRGB(196, 190, 176), Enum.Material.Concrete)
	for i = 0, 3 do
		block(folder, Vector3.new(4, 4, 4), CFrame.new(ORIGIN + Vector3.new(-30 - i * 9, 2, -40 - i * 10)), Color3.fromRGB(150, 110, 70), Enum.Material.WoodPlanks)
	end
end

local function spec(kind)
	return MountedGunData.SpecOf(kind)
end

local function place(folder, kind, at)
	local model = MountedGunModels.Build(kind, at or CFrame.new(ORIGIN))
	model:SetAttribute("VehicleModel", MountedGunData.Kinds[kind].modelId)
	model:SetAttribute("MountedGun", kind)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model.Parent = folder
	return model
end

-- The parts welded (or jointed) under `pivot`, found through the joints.
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

local function about(model, pivotName, rotation)
	local pivot = model:FindFirstChild(pivotName)
	if not pivot then
		return
	end
	local frame = pivot.CFrame
	local move = frame * rotation * frame:Inverse()
	for part in pairs(subtree(model, pivot)) do
		part.CFrame = move * part.CFrame
	end
end

local function poseGun(model, yawDeg, pitchDeg, recoil)
	if recoil and recoil ~= 0 then
		about(model, "BarrelRecoil", CFrame.new(0, 0, recoil))
	end
	about(model, "TurretPitch", CFrame.Angles(math.rad(pitchDeg), 0, 0))
	about(model, "TurretYaw", CFrame.Angles(0, math.rad(yawDeg), 0))
	-- The joints say the same, so MountRig (which reads them, as it does in a game) finds the grips posed.
	local yawJoint = model:FindFirstChild("TurretYaw") and model.TurretYaw:FindFirstChild("Joint")
	local pitchJoint = model:FindFirstChild("TurretPitch") and model.TurretPitch:FindFirstChild("Joint")
	if yawJoint and pitchJoint then
		yawJoint.Transform = CFrame.Angles(0, math.rad(yawDeg), 0)
		pitchJoint.Transform = CFrame.Angles(math.rad(pitchDeg), 0, 0)
	end
end

local R15_JOINTS = {
	{ "HumanoidRootPart", "LowerTorso", "Root" }, { "LowerTorso", "UpperTorso", "Waist" }, { "UpperTorso", "Head", "Neck" },
	{ "UpperTorso", "LeftUpperArm", "LeftShoulder" }, { "LeftUpperArm", "LeftLowerArm", "LeftElbow" },
	{ "LeftLowerArm", "LeftHand", "LeftWrist" }, { "UpperTorso", "RightUpperArm", "RightShoulder" },
	{ "RightUpperArm", "RightLowerArm", "RightElbow" }, { "RightLowerArm", "RightHand", "RightWrist" },
	{ "LowerTorso", "LeftUpperLeg", "LeftHip" }, { "LeftUpperLeg", "LeftLowerLeg", "LeftKnee" },
	{ "LeftLowerLeg", "LeftFoot", "LeftAnkle" }, { "LowerTorso", "RightUpperLeg", "RightHip" },
	{ "RightUpperLeg", "RightLowerLeg", "RightKnee" }, { "RightLowerLeg", "RightFoot", "RightAnkle" },
}

local function newRig()
	local ok, rig = pcall(function()
		local description = Instance.new("HumanoidDescription")
		description.LeftArmColor = Color3.fromRGB(204, 142, 105)
		description.RightArmColor = Color3.fromRGB(204, 142, 105)
		description.HeadColor = Color3.fromRGB(204, 142, 105)
		description.TorsoColor = Color3.fromRGB(60, 90, 160)
		description.LeftLegColor = Color3.fromRGB(40, 44, 56)
		description.RightLegColor = Color3.fromRGB(40, 44, 56)
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	return ok and rig or nil
end

local function poseRider(rig, rootFrame, pose, gun)
	local motors = {}
	for _, joint in ipairs(R15_JOINTS) do
		local part0, part1 = rig:FindFirstChild(joint[1]), rig:FindFirstChild(joint[2])
		local a0 = part0 and part0:FindFirstChild(joint[3] .. "RigAttachment")
		local a1 = part1 and part1:FindFirstChild(joint[3] .. "RigAttachment")
		if a0 and a1 then
			table.insert(motors, { name = joint[3], part0 = part0, part1 = part1, c0 = a0.CFrame, c1 = a1.CFrame })
		end
	end
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") or d:IsA("AnimationConstraint") then
			d:Destroy()
		end
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	local root = rig:FindFirstChild("HumanoidRootPart")
	local before = root.CFrame
	root.CFrame = rootFrame
	-- The joints as MountRig sees them in a game: C0, C1 and this frame's Transform; it reaches the arms.
	local fake = {}
	for _, m in ipairs(motors) do
		fake[m.name] = { C0 = m.c0, C1 = m.c1, Transform = (pose and pose[m.name]) or CFrame.identity }
	end
	if gun then
		MountRig.ArmsToGrips(rig, fake, gun)
	end
	local placed = { [root] = true }
	for _ = 1, 4 do
		for _, m in ipairs(motors) do
			if placed[m.part0] and not placed[m.part1] then
				m.part1.CFrame = m.part0.CFrame * m.c0 * fake[m.name].Transform * m.c1:Inverse()
				placed[m.part1] = true
			end
		end
	end
	local carry = root.CFrame * before:Inverse()
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") and not placed[d] then
			d.CFrame = carry * d.CFrame
		end
	end
end

local current = nil
local function stopCurrent()
	if current then
		pcall(function()
			current:Stop()
		end)
		current = nil
	end
	local old = StarterGui:FindFirstChild("GunnerSight")
	if old then
		old:Destroy()
	end
end

local function look(camera, from, at, fov)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = fov or 50
	camera.CFrame = CFrame.lookAt(from, at)
end

-- The gunner's seated root for a gun turned `yaw` and tipped `pitch` (MountedGunClient's lean, 0.45 of it).
local function gunnerRoot(model, yaw, pitch)
	local seat = model:FindFirstChild("GunnerSeat")
	local yawPart, pitchPart = model:FindFirstChild("TurretYaw"), model:FindFirstChild("TurretPitch")
	local turn = yawPart.CFrame * CFrame.Angles(0, math.rad(yaw), 0) * yawPart.CFrame:Inverse()
	local pitchAt = turn * pitchPart.CFrame
	local lean = pitchAt * CFrame.Angles(math.rad(pitch * 0.45), 0, 0) * pitchAt:Inverse()
	return lean * turn * seat.CFrame * SEAT_ROOT
end

local function handGap(rig, model, side)
	local hand = rig:FindFirstChild(side == "R" and "RightHand" or "LeftHand")
	local pitch = model:FindFirstChild("TurretPitch")
	local grip = pitch and pitch:FindFirstChild("Grip" .. side)
	if hand and grip then
		return (hand.Position - grip.WorldPosition).Magnitude
	end
	return -1
end

local views = {}
local function add(name, settle, setup)
	table.insert(views, { name = name, settle = settle or 1, setup = setup })
end

for _, kind in ipairs({ "hmg", "cannon" }) do
	for i, from in ipairs({ Vector3.new(-7.5, 4.2, -8.5), Vector3.new(10.5, 3.2, 0.5), Vector3.new(6.5, 6.5, 8) }) do
		add(string.format("%s_%s", kind, ({ "a", "b", "c" })[i]), 1, function(folder, camera)
			stopCurrent()
			stage(folder)
			local model = place(folder, kind)
			poseGun(model, i == 2 and -20 or 12, 6, 0)
			look(camera, ORIGIN + from, ORIGIN + Vector3.new(0, 2.6, 0), 50)
			local count = 0
			for _, p in ipairs(model:GetDescendants()) do
				if p:IsA("BasePart") and p.Transparency < 1 then
					count += 1
				end
			end
			note(string.format("%s: %d visible parts", kind, count))
		end)
	end
	for _, moment in ipairs({ "hip", "ads", "reload" }) do
		add(kind .. "_fp_" .. moment, 1, function(folder, camera)
			stopCurrent()
			stage(folder)
			local model = place(folder, kind)
			local names = VehicleWeaponData.Parts.turret
			local restYaw = model:FindFirstChild(names.yaw).CFrame
			local pitchPart = model:FindFirstChild(names.pitch)
			local restPivot = restYaw:PointToObjectSpace(pitchPart.Position)
			local restMouth = restYaw:VectorToObjectSpace(model:FindFirstChild(names.muzzle).Position - pitchPart.Position)
			local rig = newRig()
			if rig then
				rig.Parent = model
				rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, -40, 0)))
			end
			local s = spec(kind)
			local view = GunnerView.Start(model, s, { noInput = true, character = rig, guiParent = StarterGui })
			if not view then
				note(kind .. ": GunnerView did not start")
				return
			end
			current = view
			local yaw, pitch = 8, 3
			view.yaw, view.wantYaw, view.pitch, view.wantPitch = yaw, yaw, pitch, pitch
			local state = { ready = moment ~= "reload" }
			view:SetAiming(moment == "ads")
			for _ = 1, 50 do
				view:Update(DT, state)
			end
			poseGun(model, view.yaw, view.pitch + view.kickPitch, view.kickBack)
			local aimPoint, origin, direction = view:AimPoint()
			local sYaw, _, sOrigin, sDirection = VehicleWeaponData.Solve(s, restYaw, restPivot, restMouth, aimPoint)
			if sYaw then
				local angle = math.deg(math.acos(math.clamp(sDirection:Dot(direction), -1, 1)))
				note(string.format("%s_fp_%s: impact %.0f studs out, server line %.3f deg / %.3f studs off the barrel's -- %s", kind, moment,
					(view.impact - origin).Magnitude, angle, (sOrigin - origin).Magnitude, (angle < 0.25 and (sOrigin - origin).Magnitude < 0.25) and "AGREE" or "DISAGREE"))
			end
		end)
	end
	add(kind .. "_fire", 1, function(folder, camera)
		stopCurrent()
		stage(folder)
		local model = place(folder, kind)
		poseGun(model, 15, 4, kind == "cannon" and 0.2 or 0.12)
		local muzzle = model:FindFirstChild("TurretMuzzle")
		local flash = block(folder, Vector3.new(0.9, 0.9, 1.6), muzzle.CFrame * CFrame.new(0, 0, -0.8), Color3.fromRGB(255, 200, 90), Enum.Material.Neon)
		flash.Shape = Enum.PartType.Ball
		flash.Transparency = 0.15
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 190, 90)
		light.Range = 14
		light.Brightness = 4
		light.Parent = flash
		local port = model:FindFirstChild("TurretPitch"):FindFirstChild("EjectPoint")
		for i = 1, 4 do
			local c = block(folder, kind == "cannon" and Vector3.new(0.3, 0.16, 0.16) or Vector3.new(0.22, 0.08, 0.08),
				port.WorldCFrame * CFrame.new(0.35 * i, 0.22 * i - 0.03 * i * i, 0.05 * i) * CFrame.Angles(i, i * 2, 0), Color3.fromRGB(206, 164, 82), Enum.Material.Metal)
			c.Shape = Enum.PartType.Cylinder
		end
		look(camera, ORIGIN + Vector3.new(6.5, 5.2, 2.5), ORIGIN + Vector3.new(0, 4, -1.2), 50)
	end)
	add(kind .. "_3p", 1, function(folder, camera)
		stopCurrent()
		stage(folder)
		local model = place(folder, kind)
		local yaw, pitch = 25, 6
		poseGun(model, yaw, pitch, 0)
		local rig = newRig()
		if rig then
			rig.Parent = folder
			poseRider(rig, gunnerRoot(model, yaw, pitch), VehicleModels.Poses.GunnerStand, model)
			local head = rig:FindFirstChild("Head")
			local eye = model:FindFirstChild("TurretPitch"):FindFirstChild("GunnerEye")
			note(string.format("%s_3p: hands %.2f / %.2f from the grips, eyes %.2f from GunnerEye, feet lowest %.2f above the floor", kind,
				handGap(rig, model, "R"), handGap(rig, model, "L"), head and (head.Position - eye.WorldPosition).Magnitude or -1,
				math.min(rig.LeftFoot.Position.Y - rig.LeftFoot.Size.Y / 2, rig.RightFoot.Position.Y - rig.RightFoot.Size.Y / 2) - ORIGIN.Y))
		end
		look(camera, ORIGIN + Vector3.new(-9, 5, 10), ORIGIN + Vector3.new(0, 3, 0), 48)
	end)
end

add("hmg_overheat", 1, function(folder, camera)
	stopCurrent()
	stage(folder)
	local model = place(folder, "hmg")
	poseGun(model, -10, 8, 0)
	for name in string.gmatch(model:GetAttribute("HeatParts") or "", "[^,]+") do
		local part = model:FindFirstChild(name)
		if part then
			part.Color = part.Color:Lerp(Color3.fromRGB(255, 118, 40), 0.85)
			part.Material = Enum.Material.Neon
		end
	end
	local at = model:FindFirstChild("TurretPitch"):FindFirstChild("SteamPoint")
	for i = 1, 7 do
		local puff = block(folder, Vector3.new(0.5 + i * 0.25, 0.5 + i * 0.25, 0.5 + i * 0.25),
			at.WorldCFrame * CFrame.new(math.sin(i) * 0.3, 0.35 * i, -0.2 * i), Color3.fromRGB(235, 235, 240))
		puff.Shape = Enum.PartType.Ball
		puff.Transparency = 0.45 + i * 0.06
		puff.CanCollide = false
	end
	look(camera, ORIGIN + Vector3.new(7, 5.5, -5), ORIGIN + Vector3.new(0, 4.3, -1.3), 45)
end)

for step, t in ipairs({ 0, 0.5, 1 }) do
	add("mount_" .. step, 1, function(folder, camera)
		stopCurrent()
		stage(folder)
		local model = place(folder, "hmg")
		local rig = newRig()
		if rig then
			rig.Parent = folder
			local seated = gunnerRoot(model, 0, 0)
			local standing = CFrame.new(ORIGIN + Vector3.new(1.2, 3.0, 5.2)) * CFrame.Angles(0, math.rad(20), 0)
			local s = t * t * (3 - 2 * t)
			local posed = {}
			for joint, transform in pairs(VehicleModels.Poses.GunnerStand) do
				posed[joint] = CFrame.identity:Lerp(transform, s)
			end
			poseRider(rig, standing:Lerp(seated, s), posed, t >= 1 and model or nil)
		end
		look(camera, ORIGIN + Vector3.new(-8, 5.5, 9), ORIGIN + Vector3.new(0, 3, 1.5), 50)
	end)
end

add("sweep", 1, function(folder, camera)
	stopCurrent()
	stage(folder)
	local model = place(folder, "hmg")
	local s = spec("hmg")
	local view = GunnerView.Start(model, s, { noInput = true, guiParent = StarterGui })
	if not view then
		note("sweep: GunnerView did not start")
		return
	end
	current = view
	local yaws, worst, over, prev = {}, 0, 0, 0
	for frame = 1, 150 do
		local want = frame < 60 and 200 or -200
		view.wantYaw, view.wantPitch = GunnerView.Pure.clampLook(s, want, 0)
		view:Update(DT, { ready = true })
		worst = math.max(worst, math.abs(view.yaw - prev))
		over = math.max(over, math.abs(view.yaw) - s.yawLimit)
		prev = view.yaw
		table.insert(yaws, string.format("%.1f", view.yaw))
	end
	note(string.format("sweep yaw per frame at 60 fps: worst step %.2f deg (cap %.2f), past the arc %.3f deg: %s", worst, s.slew / 60, math.max(0, over),
		table.concat(yaws, " ")))
	look(camera, ORIGIN + Vector3.new(-6, 6, 8), ORIGIN + Vector3.new(0, 3, 0), 50)
end)

add("map_emplacement", 6, function(folder, camera)
	stopCurrent()
	math.randomseed(20260924)
	local MapGenerator = require(modules:WaitForChild("MapGenerator"))
	local MountedGunPlacement = require(modules:WaitForChild("MountedGunPlacement"))
	local info = MapGenerator.Build("PatapimPlains")
	local spots, rejected, considered = MountedGunPlacement.Choose(info, 777, MapGenerator.GroundHeightAt)
	local tally = {}
	for why, n in pairs(rejected) do
		table.insert(tally, why .. " " .. n)
	end
	table.sort(tally)
	note(string.format("map PatapimPlains (radius %d): %d guns from %d candidates; rejected: %s", info.radius, #spots, considered, table.concat(tally, ", ")))
	for i, sp in ipairs(spots) do
		local covers = {}
		for k, n in pairs(sp.details.covers or {}) do
			table.insert(covers, n .. " " .. k)
		end
		table.sort(covers)
		note(string.format("  #%d %s at (%.0f, %.0f, %.0f) %s spot, score %.1f, rise %.1f, sightline %.0f, cover %d, flank routes %d, covers %s",
			i, sp.kind, sp.cframe.X, sp.cframe.Y, sp.cframe.Z, sp.why or "?", sp.score, sp.details.rise, sp.details.median, sp.details.covered,
			sp.details.routes, table.concat(covers, ", ")))
		place(folder, sp.kind, sp.cframe)
	end
	local best = spots[1]
	if best then
		local from = best.cframe * CFrame.new(3, 9, 14)
		look(camera, from.Position, (best.cframe * CFrame.new(0, 2, -30)).Position, 60)
	else
		look(camera, Vector3.new(0, 600, 300), Vector3.zero, 70)
	end
end)

-- Every vehicle's turret: three angles close in on the gun, and its sight through GunnerView (aimed).
local vehicleIds = {}
for modelId in pairs(VehicleModels.Mounts) do
	table.insert(vehicleIds, modelId)
end
table.sort(vehicleIds)
local function vehicle(folder, modelId)
	local model = VehicleModels.Build(modelId, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 0.5, 0)))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	return model
end
for _, modelId in ipairs(vehicleIds) do
	-- Close on the gun (the whole vehicle is in the vehicle galleries): front quarter, side, rear quarter.
	for i, from in ipairs({ Vector3.new(-3.2, 1.6, -3.8), Vector3.new(4.6, 1.1, 0.4), Vector3.new(2.4, 2.4, 4.0) }) do
		add(string.format("veh_%s_%s", modelId, ({ "a", "b", "c" })[i]), 1, function(folder, camera)
			stopCurrent()
			stage(folder)
			local model = vehicle(folder, modelId)
			local s = VehicleWeaponData.ForModel(modelId, "turret")
			local pitch = math.max((s.restPitch or 0) + 4, math.deg(VehicleWeaponData.PitchFloor(s, math.rad(20))))
			poseGun(model, 20, pitch, 0)
			local at = model:FindFirstChild("TurretPitch").Position
			look(camera, at + from, at, 50)
		end)
	end
	add(string.format("veh_%s_sight", modelId), 1, function(folder, camera)
		stopCurrent()
		stage(folder)
		local model = vehicle(folder, modelId)
		local s = VehicleWeaponData.ForModel(modelId, "turret")
		local rig = newRig()
		if rig then
			rig.Parent = model
			rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, -40, 0)))
		end
		local view = GunnerView.Start(model, s, { noInput = true, character = rig, guiParent = StarterGui })
		if not view then
			note(modelId .. ": GunnerView did not start")
			return
		end
		current = view
		local pitch = math.max((s.restPitch or 0) + 2, math.deg(VehicleWeaponData.PitchFloor(s, math.rad(10))))
		if s.kind == "round" and s.pitchMin >= 0 then
			-- A lobbing gun laid on a long landing, on a field wide enough to come down on (the stage's
			-- own is 700 across), so its range ladder is on the ground.
			pitch = 40
			block(folder, Vector3.new(3000, 1, 3000), CFrame.new(ORIGIN - Vector3.new(0, 0.6, 0)), Color3.fromRGB(108, 120, 86), Enum.Material.Grass)
		end
		view.yaw, view.wantYaw, view.pitch, view.wantPitch = 10, 10, pitch, pitch
		view:SetAiming(true)
		for _ = 1, 50 do
			view:Update(DT, { ready = true })
		end
		poseGun(model, view.yaw, view.pitch + view.kickPitch, 0)
	end)
end

add("zz_cleanup", 0.3, function(_, camera)
	stopCurrent()
	camera.CameraType = Enum.CameraType.Fixed
end)

if ONLY then
	local kept = {}
	for _, v in ipairs(views) do
		for _, prefix in ipairs(ONLY) do
			if string.sub(v.name, 1, #prefix) == prefix or v.name == "zz_cleanup" then
				table.insert(kept, v)
				break
			end
		end
	end
	views = kept
end

return views
