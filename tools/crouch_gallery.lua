-- Crouch, slide, climb and vault: what they actually look like on a body. Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crouch_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Every frame is a real R15 with a gun in its hands, lit, close, and standing against the obstacle the
-- move is for — a low wall to crouch behind, a crate to climb, a rail to vault. The poses come from the
-- same modules the game runs (Shared/CrouchAnimation, Shared/Parkour), applied to the same joints
-- (Shared/Parkour.PoseJoints), in Run mode so the Animator is there and the joints render exactly as a
-- player would see them. Nothing here is drawn by hand for the picture.
--
-- The crouch set walks the whole move: dropping in (two frames), held, four frames of the walk cycle a
-- quarter-turn apart, and standing back up. The parkour set does the same for the slide, the mantle and
-- the vault, which have never been photographed close up.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CrouchAnimation = require(Shared:WaitForChild("CrouchAnimation"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local modules = ServerScriptService:WaitForChild("Modules")
local CROUCH = MovementConfig.Crouch
local GUN = "CrocodiloRifle"
local BASE = Vector3.new(7200, 400, 7200)
local pi = math.pi

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function V(x, y, z)
	return Vector3.new(x, y, z)
end

local function block(parent, size, cframe, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

--------------------------------------------------------------------------------
-- The stage: ground, light, a body with a gun in its hands
--------------------------------------------------------------------------------

local rigTemplate
local function newRig(folder, at, facing)
	if not rigTemplate then
		for _ = 1, 3 do
			local ok, model = pcall(function()
				return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
			end)
			if ok and model then
				rigTemplate = model
				break
			end
			task.wait(2)
		end
	end
	if not rigTemplate then
		note("no R15 rig available; every frame here will be empty")
		return nil
	end
	local rig = rigTemplate:Clone()
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	humanoid.WalkSpeed = 0
	rig.Parent = folder
	local root = rig:WaitForChild("HumanoidRootPart")
	rig:PivotTo(CFrame.lookAt(at + V(0, humanoid.HipHeight + root.Size.Y / 2, 0), at + facing * 10))
	-- Only the root is anchored: an anchored limb cannot be moved by its joint, so anchoring the whole
	-- rig would photograph the standing pose no matter what we wrote onto it.
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = part.Name == "HumanoidRootPart"
		end
	end
	-- A stock rig from a description is a PHYSICS rig: its joints are AnimationConstraints driven by
	-- torque. Marking them kinematic is not enough here — over the couple of seconds a frame is held, the
	-- limbs lose to gravity and the whole body collapses into a heap. (It survived the probe only because
	-- that measures 0.2 s in, before the collapse; the first usable renders showed a STANDING rig with no
	-- pose on it looking exactly as mangled as a crouched one, which is what gave it away.)
	--
	-- So the rig is converted to Motor6Ds, which is what a player's character actually has: rigid, no sag,
	-- and the same joint type this animation drives in the game. A gallery of a player's move should be
	-- photographed on a player's rig.
	local converted = 0
	for _, joint in ipairs(rig:GetDescendants()) do
		if joint:IsA("AnimationConstraint") then
			local a0, a1 = joint.Attachment0, joint.Attachment1
			if a0 and a1 and a0.Parent and a1.Parent then
				local motor = Instance.new("Motor6D")
				motor.Name = joint.Name
				motor.Part0 = a0.Parent
				motor.Part1 = a1.Parent
				motor.C0 = a0.CFrame
				motor.C1 = a1.CFrame
				motor.Parent = joint.Parent
				joint:Destroy()
				converted += 1
			end
		end
	end
	-- The humanoid's own balance controller fights anything holding a limb still; with the root anchored
	-- it has nothing to balance anyway.
	humanoid.PlatformStand = true
	if converted > 0 then
		note(string.format("rig: converted %d AnimationConstraints to Motor6Ds", converted))
	end
	-- READABILITY. A stock rig is near-black and every limb is the same near-black, so the whole body
	-- merges into one silhouette and no pose can be read off it — which is what the first three attempts
	-- at this gallery were really showing. Adjacent segments are given different tones, light to dark down
	-- the body, the way a reference mannequin is painted. Nothing here changes the pose; it only makes the
	-- pose visible.
	local TONES = {
		Head = Color3.fromRGB(238, 228, 212),
		UpperTorso = Color3.fromRGB(214, 202, 186),
		LowerTorso = Color3.fromRGB(190, 178, 162),
		LeftUpperArm = Color3.fromRGB(176, 186, 200), RightUpperArm = Color3.fromRGB(176, 186, 200),
		LeftLowerArm = Color3.fromRGB(150, 162, 180), RightLowerArm = Color3.fromRGB(150, 162, 180),
		LeftHand = Color3.fromRGB(128, 140, 160), RightHand = Color3.fromRGB(128, 140, 160),
		-- The legs carry the whole crouch, so they get the most separation.
		LeftUpperLeg = Color3.fromRGB(226, 170, 120), RightUpperLeg = Color3.fromRGB(208, 150, 100),
		LeftLowerLeg = Color3.fromRGB(150, 120, 96), RightLowerLeg = Color3.fromRGB(132, 104, 82),
		LeftFoot = Color3.fromRGB(78, 68, 60), RightFoot = Color3.fromRGB(62, 54, 48),
	}
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") and TONES[part.Name] then
			part.Color = TONES[part.Name]
			part.Material = Enum.Material.SmoothPlastic
		end
	end
	-- A gun, because a body without one reads as a mannequin and hides how the arms sit.
	local ok, err = pcall(function()
		local WeaponService = require(modules:WaitForChild("WeaponService"))
		local def = WeaponData.Get(GUN)
		-- BuildGunModel returns the model AND its receiver; the receiver is what MountGun welds to the
		-- torso. Passing a guessed part left the weld with no Part0, and an unwelded gun parked itself in
		-- front of the camera and filled every frame.
		local model, receiver = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal,
			{ detail = "full" })
		local mounted = receiver ~= nil and WeaponService.MountGun(rig, model, receiver)
		if not mounted then
			note("gun: not mounted (receiver " .. tostring(receiver) .. "); rendering without one")
			if model and model.Parent == nil then
				model:Destroy()
			end
		end
	end)
	if not ok then
		note("gun: " .. tostring(err))
	end
	return rig, humanoid, root
end

local function stage(folder, props)
	block(folder, V(60, 2, 60), CFrame.new(BASE - V(0, 1, 0)), {
		Name = "Ground", Material = Enum.Material.Concrete, Color = Color3.fromRGB(150, 150, 155),
	})
	-- A default rig is dark, and two small point lights left it reading as a black mass with the fold in
	-- the legs invisible — which is the whole subject. So: lift the scene's own light first, then a key
	-- from the camera's side and a fill opposite for the shape.
	Lighting.Brightness = 3
	Lighting.Ambient = Color3.fromRGB(120, 120, 128)
	Lighting.OutdoorAmbient = Color3.fromRGB(140, 140, 150)
	Lighting.GlobalShadows = true
	Lighting.ClockTime = 14
	for _, spec in ipairs({ { V(-10, 12, -12), 6 }, { V(12, 8, 10), 3 } }) do
		local light = Instance.new("PointLight")
		light.Range = 60
		light.Brightness = spec[2]
		light.Parent = block(folder, V(1, 1, 1), CFrame.new(BASE + spec[1]), { Transparency = 1, CanCollide = false })
	end
	for key, value in pairs(props or {}) do
		Lighting[key] = value
	end
end

-- Frames a body from a given direction. `subject` overrides the size fitted to, which matters more than
-- it sounds: fitting each frame to its OWN body makes a crouched one fill the frame exactly as a standing
-- one does, so the 1-stud drop — the entire point of the picture — disappears. The crouch set therefore
-- fits every frame to the STANDING size and lets the crouched body sit visibly lower and smaller in it.
local function frameBody(camera, model, direction, fov, subject, aimAt)
	local box, size = model:GetBoundingBox()
	local radius = math.max((subject or size.Magnitude) / 2, 1)
	camera.FieldOfView = fov or 40
	local distance = radius / math.tan(math.rad(camera.FieldOfView / 2)) * 1.25
	local target = aimAt or box.Position
	camera.CFrame = CFrame.lookAt(target + direction.Unit * distance, target)
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local views = {}

-- A view is one frozen frame. `build` stages it and returns a function that re-applies the pose; the
-- step callback runs it every frame, because Studio's own animation would otherwise blend it away.
-- Both close over their own view, so nothing here depends on the order the list is built in.
local function moment(name, build)
	local view = { name = name, settle = 1.2, hold = 0.6 }
	view.setup = function(folder, camera)
		if not RunService:IsRunning() then
			RunService:Run()
		end
		view.held = build(folder, camera)
	end
	view.step = function()
		if view.held then
			view.held()
		end
	end
	table.insert(views, view)
	return view
end

-- The crouch, against a wall low enough to shoot over standing and hide behind crouched.
--
-- `spec` is { torso, legs, hipDown, phase, walk, framing }, and it mirrors the game exactly: the body's
-- height and the fold in the legs are NOT eased (MatchService drops HipHeight on the frame the crouch
-- starts, and the legs follow it or the feet go through the floor) — only the spine eases. So the one
-- transition frame here shows a body already down with its torso still catching up, which is what a
-- player really sees, rather than a half-lowered body that never exists.
local function crouchMoment(name, spec)
	moment(name, function(folder, camera)
		stage(folder)
		-- The wall sits on the +X side, which is also where the body FACES. A camera in front of the body
		-- therefore looks straight through it, which is how the first "front" render came out as a picture
		-- of brickwork with a head above it. Views that want the body's front leave the wall out.
		if spec.wall ~= false then
			block(folder, V(1.4, 3.6, 14), CFrame.new(BASE + V(2.6, 1.8, 0)), {
				Name = "CoverWall", Material = Enum.Material.Brick, Color = Color3.fromRGB(122, 84, 72),
			})
		end
		local rig, humanoid, root = newRig(folder, BASE, V(1, 0, 0))
		if not rig then
			return nil
		end
		local segments = CrouchAnimation.Segments(rig)
		local standHip = humanoid.HipHeight
		local crouchHip = math.max(standHip * CROUCH.HipScale, CROUCH.MinHipHeight)
		local hip = spec.hipDown and crouchHip or standHip
		humanoid.HipHeight = hip
		rig:PivotTo(CFrame.lookAt(BASE + V(0, hip + root.Size.Y / 2, 0), BASE + V(10, hip + root.Size.Y / 2, 0)))
		local joints = Parkour.PoseJoints(rig)
		if not joints then
			note(name .. ": the rig has no pose joints")
			return nil
		end
		local depth = CrouchAnimation.Depth(segments, standHip - hip)
		local stride = CrouchAnimation.Stride(segments)
		local pose = CrouchAnimation.Pose({
			phase = spec.phase or 0, walk = spec.walk or 0, clock = 0,
			segments = segments, depth = depth, stride = stride,
		})
		note(string.format("%s: hip %.2f (standing %.2f), hips %.2f over the soles, step %.2f, torso %.2f, legs %.2f",
			name, hip, standHip, depth, stride / 2, spec.torso or 0, spec.legs or 0))
		-- Pose FIRST, then frame: the bounding box of a crouched body is not the box of a standing one,
		-- and framing before the fold is what cropped the first set at the chest.
		local applied = function()
			CrouchAnimation.Apply(joints, pose, spec.torso or 0, spec.legs or 0)
		end
		applied()
		task.wait()
		-- Every crouch frame is framed identically: same distance, same aim point, sized to a STANDING
		-- body. A crouched one then reads as shorter, which is what the set is for.
		frameBody(camera, rig, spec.framing or V(-0.85, 0.35, -1), 40, 7.4, BASE + V(0, 2.4, 0))
		return applied
	end)
end

-- Standing first, same framing and same wall, so the drop is a comparison rather than a claim.
crouchMoment("crouch_0_standing_for_comparison", { torso = 0, legs = 0, hipDown = false })
crouchMoment("crouch_1_entering_torso_catching_up", { torso = 0.4, legs = 1, hipDown = true })
crouchMoment("crouch_2_held", { torso = 1, legs = 1, hipDown = true })
crouchMoment("crouch_3_walk_plant", { torso = 1, legs = 1, hipDown = true, phase = 0, walk = 1 })
crouchMoment("crouch_4_walk_pass", { torso = 1, legs = 1, hipDown = true, phase = pi / 2, walk = 1 })
crouchMoment("crouch_5_walk_swap", { torso = 1, legs = 1, hipDown = true, phase = pi, walk = 1 })
crouchMoment("crouch_6_walk_reach", { torso = 1, legs = 1, hipDown = true, phase = 3 * pi / 2, walk = 1 })
-- From the front, so the stance and the gun read.
crouchMoment("crouch_7_front", { torso = 1, legs = 1, hipDown = true, phase = pi / 2, walk = 1,
	framing = V(1, 0.3, 0.15), wall = false })
-- And from the defender's side of the wall: what someone shooting at you sees.
crouchMoment("crouch_8_over_the_wall", { torso = 1, legs = 1, hipDown = true, framing = V(1, 0.55, -0.6) })
-- One clean side-on frame with nothing behind the body, so the fold in the legs reads on its own.
crouchMoment("crouch_9_legs_side_on", { torso = 1, legs = 1, hipDown = true, phase = pi / 2, walk = 1,
	framing = V(0, 0.12, -1), wall = false })

-- The parkour poses, each against the thing it is for.
local function parkourMoment(name, kind, weight, build, framing, focus)
	moment(name, function(folder, camera)
		stage(folder)
		local rig, _, root = newRig(folder, BASE, V(1, 0, 0))
		if not rig then
			return nil
		end
		local at = build(folder, rig, root)
		local joints = Parkour.PoseJoints(rig)
		if not joints then
			note(name .. ": the rig has no pose joints")
			return nil
		end
		-- Pose first, then frame the posed body: a mantle reaches a long way above where the rig started,
		-- and framing off a fixed point put the camera in the wrong place for two of these three.
		local applied = function()
			Parkour.ApplyPose(joints, kind, weight)
		end
		applied()
		task.wait()
		frameBody(camera, rig, framing or V(-0.9, 0.45, -1), 40)
		return applied
	end)
end

parkourMoment("slide_1_low", "slide", 1, function(folder, rig, root)
	block(folder, V(24, 2, 14), CFrame.new(BASE + V(6, -1, 0)), {
		Name = "Lane", Material = Enum.Material.Asphalt, Color = Color3.fromRGB(88, 88, 92),
	})
	rig:PivotTo(CFrame.lookAt(BASE + V(0, root.Size.Y / 2 + 1.1, 0), BASE + V(10, root.Size.Y / 2 + 1.1, 0)))
	return nil
end, V(-1, 0.35, -0.9))

parkourMoment("mantle_1_pull_up", "mantle", 1, function(folder, rig, root)
	local ledge = block(folder, V(6, 6, 14), CFrame.new(BASE + V(5.2, 3, 0)), {
		Name = "Ledge", Material = Enum.Material.Slate, Color = Color3.fromRGB(96, 100, 110),
	})
	-- Hands on the lip, chest at the top: where the pull-up actually happens.
	local top = ledge.Position.Y + ledge.Size.Y / 2
	rig:PivotTo(CFrame.lookAt(BASE + V(0.6, top - 1.6 + root.Size.Y / 2, 0), BASE + V(10, top - 1.6 + root.Size.Y / 2, 0)))
	return V(0, 2.4, 0)
end, V(-1, 0.5, -1))

parkourMoment("vault_1_over_the_rail", "vault", 1, function(folder, rig, root)
	block(folder, V(1.2, 3.6, 14), CFrame.new(BASE + V(3.4, 1.8, 0)), {
		Name = "Rail", Material = Enum.Material.Metal, Color = Color3.fromRGB(140, 142, 150),
	})
	rig:PivotTo(CFrame.lookAt(BASE + V(2.4, 2.9 + root.Size.Y / 2, 0), BASE + V(12, 2.9 + root.Size.Y / 2, 0)))
	return V(1.6, 1.6, 0)
end, V(-1, 0.45, -1))

return views
