-- The gun rework gallery (2026-09-24): every signature gun, and the new guns' rounds in action.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/gunfun_gallery.lua -OutDir <folder>
--
-- Per gun (every id GunModelsSignature builds, Common first): a three-quarter view and a side view of the model
-- the hand, the floor and the podium all use; the first-person view at the hip and aimed, posed by the game's
-- own Viewmodel with a default avatar's arms; and a frame of its signature inspect (the Flair clip). The three
-- new guns also get a frame of their draw flourish.
--
-- Then the mechanics, drawn from the game's own numbers (Ballistics, CombatService.Patterns):
--   rounds            the dart, the drumlet and the banana boomerang as they look in flight, big;
--   bananerang_path   a throw from above: out, the hang, and back along the same curve past a dummy it cuts twice;
--   dart_homing       two darts at a dummy 40 studs out: 2 studs off (pulled on) and 8 off (left alone);
--   drumlet_volley    one shot's three drumlets bouncing down a street, and the blasts where they burst;
--   patterns          the Nonna's heart, the Backrooms Breacher's door and the Tamburo's fan on a wall.
--
-- Set ONLY to a list of ids to render just those guns (the mechanics views always render).

local ONLY = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local GunModelsSignature = require(Shared:WaitForChild("GunModelsSignature"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))
local Modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponService = require(Modules:WaitForChild("WeaponService"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))
-- Patterns only; a server module, so it is allowed to fail here and the patterns view then says so.
local okCombat, CombatService = pcall(require, Modules:WaitForChild("CombatService"))

local NEW = { ZanzarinoPikpik = true, TamburoTungTung = true, Bananerang = true }
local MM = GunModels.StudsPerMillimetre
local ORIGIN = Vector3.new(0, 700, 3000)
local VM_ORIGIN = Vector3.new(0, 600, 0)
local MECH = Vector3.new(0, 800, -3000)
local V = Vector3.new
Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	avatar = nil
end

local ids = {}
for id in pairs(GunModelsSignature.Builders) do
	if WeaponData.Get(id) and (not ONLY or table.find(ONLY, id)) then
		table.insert(ids, id)
	end
end
table.sort(ids, function(a, b)
	local ra, rb = Rarity.Index[WeaponData.Get(a).rarity] or 0, Rarity.Index[WeaponData.Get(b).rarity] or 0
	if ra ~= rb then
		return ra < rb
	end
	return a < b
end)

--------------------------------------------------------------------------------
-- Scenery
--------------------------------------------------------------------------------

local function block(folder, size, cframe, color, material, transparency)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = true
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Transparency = transparency or 0
	part.Parent = folder
	return part
end

local function dot(folder, position, color, size)
	local part = block(folder, V(size, size, size), position, color, Enum.Material.Neon)
	part.Shape = Enum.PartType.Ball
	part.CanCollide = false
	return part
end

local function backdrop(folder, position, facing)
	block(folder, V(90, 90, 1), CFrame.lookAt(position, position + facing), Color3.fromRGB(198, 206, 212))
end

local function room(folder)
	block(folder, V(80, 1, 120), VM_ORIGIN + V(0, -5.5, -40), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(folder, V(80, 40, 1), VM_ORIGIN + V(0, 10, -60), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(folder, V(4, 4, 0.2), VM_ORIGIN + V(0, 0, -59.4), Color3.fromRGB(210, 60, 50))
	block(folder, V(2, 2, 0.2), VM_ORIGIN + V(0, 0, -59.2), Color3.fromRGB(240, 236, 226))
end

-- A plain dummy standing on `feet`: legs, torso, arms and head, about a player's size.
local function dummy(folder, feet, color)
	block(folder, V(2, 2, 1), feet + V(0, 3, 0), color)
	block(folder, V(0.9, 2, 1), feet + V(-0.5, 1, 0), color:Lerp(Color3.new(0, 0, 0), 0.25))
	block(folder, V(0.9, 2, 1), feet + V(0.5, 1, 0), color:Lerp(Color3.new(0, 0, 0), 0.25))
	block(folder, V(0.8, 2, 1), feet + V(-1.45, 3, 0), color)
	block(folder, V(0.8, 2, 1), feet + V(1.45, 3, 0), color)
	local head = block(folder, V(1.2, 1.2, 1.2), feet + V(0, 4.6, 0), Color3.fromRGB(240, 210, 170))
	head.Shape = Enum.PartType.Ball
end

local function floor(folder, centre, size)
	return block(folder, V(size, 1, size), centre + V(0, -0.5, 0), Color3.fromRGB(104, 118, 96), Enum.Material.Grass)
end

--------------------------------------------------------------------------------
-- Guns
--------------------------------------------------------------------------------

local function gunView(id, direction, distance, fov)
	return function(folder, camera)
		local def = WeaponData.Get(id)
		local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		model:PivotTo(CFrame.new(ORIGIN))
		model.Parent = folder
		local target = ORIGIN + V(0, -10, -120) * MM
		local eye = target + direction.Unit * distance * MM
		backdrop(folder, target - direction.Unit * 14, direction.Unit)
		camera.FieldOfView = fov
		camera.CFrame = CFrame.lookAt(eye, target)
	end
end

local function handsView(id, state, fov)
	return function(folder, camera)
		room(folder)
		local def = WeaponData.Get(id)
		local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
		vm.model.Parent = folder
		local eye = CFrame.new(VM_ORIGIN)
		local pose = table.clone(state)
		pose.magSize = def.magSize
		vm:Pose(eye, pose)
		camera.FieldOfView = fov
		camera.CFrame = eye
	end
end

--------------------------------------------------------------------------------
-- Mechanics
--------------------------------------------------------------------------------

local function roundsView(folder, camera)
	backdrop(folder, MECH + V(0, 0, -12), V(0, 0, 1))
	for index, kind in ipairs({ "mosquitoDart", "drumlet", "bananerang" }) do
		local model = ThrowableModels.Round(kind, 4)
		model:PivotTo(CFrame.new(MECH + V((index - 2) * 5, 0, 0)) * CFrame.Angles(math.rad(-25), math.rad(35), 0))
		model.Parent = folder
	end
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(MECH + V(0, 3, 16), MECH)
end

local function boomerangView(folder, camera)
	local base = MECH + V(200, 0, 0)
	floor(folder, base + V(0, 0, -28), 90)
	dummy(folder, base, Color3.fromRGB(90, 120, 200))
	local spec = Ballistics.Rounds.bananerang
	local memory = Ballistics.BoomerangMemory(V(0, 0, -spec.speed))
	local reach = spec.speed * Ballistics.Boomerang.time / math.pi
	-- The dummy it cuts stands on its path, 30 studs out (the path bends curve x d^2 / reach to the right).
	dummy(folder, base + V(Ballistics.Boomerang.curve * 900 / reach, 0, -30), Color3.fromRGB(200, 70, 60))
	local position = base + V(0, 4.5, 0)
	local t, dt, step = 0, 1 / 60, 0
	local apex = position
	while t < spec.maxTime do
		t += dt
		step += 1
		position += Ballistics.BoomerangVelocity(memory, t - dt / 2) * dt
		if position.Z < apex.Z then
			apex = position
		end
		if step % 3 == 0 then
			local out = t < Ballistics.Boomerang.time / 2
			dot(folder, position + V(0, out and 0.35 or -0.35, 0), out and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(255, 140, 40), 0.45)
		end
	end
	local model = ThrowableModels.Round("bananerang", 3)
	model:PivotTo(CFrame.new(apex))
	model.Parent = folder
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(base + V(34, 46, -6), base + V(0, 2, -30))
end

local function dartView(folder, camera)
	local base = MECH + V(400, 0, 0)
	floor(folder, base + V(0, 0, -22), 70)
	local target = base + V(0, 0, -40)
	dummy(folder, target, Color3.fromRGB(200, 70, 60))
	local centre = target + V(0, 3, 0)
	local spec = Ballistics.Rounds.mosquitoDart
	local api = {
		Targets = function(position, range)
			if (centre - position).Magnitude <= range then
				return { { root = { Position = centre } } }
			end
			return {}
		end,
	}
	for _, shot in ipairs({ { 2, Color3.fromRGB(90, 230, 120) }, { 8, Color3.fromRGB(240, 80, 80) } }) do
		local origin = base + V(0, 3, 0)
		local entry = { spec = spec, owner = "gallery", age = 0, position = origin, velocity = (centre + V(shot[1], 0, 0) - origin).Unit * spec.speed }
		local dt = 1 / 120
		while entry.age < 0.4 do
			entry.age += dt
			entry.position, entry.velocity = Ballistics.FreeStep(entry, dt, workspace.Gravity, api)
			dot(folder, entry.position, shot[2], 0.18)
		end
	end
	local model = ThrowableModels.Round("mosquitoDart", 3)
	model:PivotTo(CFrame.lookAt(base + V(0, 3, -8), base + V(0.4, 3, -20)))
	model.Parent = folder
	camera.FieldOfView = 48
	camera.CFrame = CFrame.lookAt(base + V(-14, 22, 6), base + V(1, 2, -26))
end

local function drumletView(folder, camera)
	local base = MECH + V(600, 0, 0)
	local ground = floor(folder, base + V(0, 0, -30), 90)
	local wall = block(folder, V(40, 12, 1), base + V(0, 6, -52), Color3.fromRGB(170, 160, 150), Enum.Material.Brick)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { ground, wall }
	local function cast(origin, radius, displacement)
		local result = workspace:Spherecast(origin, radius, displacement, params)
		return result and { Position = result.Position, Normal = result.Normal, Distance = result.Distance, Instance = result.Instance } or nil
	end
	local spec = Ballistics.Rounds.drumlet
	local def = WeaponData.Get("TamburoTungTung")
	local origin = base + V(0, 4.5, 0)
	local aim = V(0, -0.05, -1).Unit
	for index = 1, def.pellets do
		local direction = aim
		if okCombat and CombatService.PelletDirection then
			direction = CombatService.PelletDirection(aim, def.spread, def, index)
		end
		local body = { position = origin, velocity = direction * spec.speed + V(0, Ballistics.DrumletLift, 0), spec = spec, resting = false }
		local age, contacts, dt = 0, 0, 1 / 60
		while age < spec.fuse do
			age += dt
			if Ballistics.StepBody(body, dt, workspace.Gravity * 1, cast) then
				contacts += 1
				dot(folder, body.position, Color3.fromRGB(255, 255, 255), 0.5)
				if contacts >= spec.maxBounces then
					break
				end
			end
			if math.floor(age / dt) % 2 == 0 then
				dot(folder, body.position, Color3.fromRGB(230, 60, 70), 0.22)
			end
		end
		local blast = block(folder, V(1, 1, 1) * def.splashRadius * 2, body.position, Color3.fromRGB(255, 170, 60), Enum.Material.Neon, 0.75)
		blast.Shape = Enum.PartType.Ball
		blast.CanCollide = false
		local model = ThrowableModels.Round("drumlet", 2)
		model:PivotTo(CFrame.new(body.position + V(0, 1, 0)))
		model.Parent = folder
	end
	camera.FieldOfView = 55
	camera.CFrame = CFrame.lookAt(base + V(26, 22, 8), base + V(0, 0, -26))
end

local function patternsView(folder, camera)
	local base = MECH + V(800, 0, 0)
	block(folder, V(60, 24, 1), base + V(0, 0, -12.5), Color3.fromRGB(226, 222, 212))
	if not (okCombat and CombatService.PelletDirection) then
		block(folder, V(10, 10, 1), base + V(0, 0, -12), Color3.fromRGB(220, 40, 40))
	else
		for column, id in ipairs({ "NonnaDoubleBarrel", "BackroomsBreacher", "TamburoTungTung" }) do
			local def = WeaponData.Get(id)
			local muzzle = base + V((column - 2) * 18, 0, 0)
			local colors = { Color3.fromRGB(230, 60, 110), Color3.fromRGB(60, 110, 230), Color3.fromRGB(240, 160, 40) }
			for shot = 1, 3 do
				for index = 1, def.pellets do
					local direction = CombatService.PelletDirection(V(0, 0, -1), def.spread, def, index)
					local hit = muzzle + direction * (12 / -direction.Z)
					dot(folder, hit, colors[shot], 0.35)
				end
			end
		end
	end
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(base + V(0, 0, 18), base + V(0, 0, -12))
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			backdrop(folder, ORIGIN + V(0, 0, -20), V(0, 0, 1))
			camera.CFrame = CFrame.lookAt(ORIGIN + V(0, 0, 6), ORIGIN)
		end,
	},
}

for _, id in ipairs(ids) do
	table.insert(views, { name = id .. "_quarter", setup = gunView(id, V(0.85, 0.35, -0.5), 1250, 42) })
	table.insert(views, { name = id .. "_side", setup = gunView(id, V(1, 0.06, 0), 1250, 42) })
	table.insert(views, { name = id .. "_hip", setup = handsView(id, { aim = 0 }, 70) })
	table.insert(views, { name = id .. "_ads", setup = handsView(id, { aim = 1 }, 70 * 0.64) })
	table.insert(views, { name = id .. "_inspect", setup = handsView(id, { clip = "inspect", progress = 0.45 }, 70) })
	if NEW[id] then
		table.insert(views, { name = id .. "_draw", setup = handsView(id, { clip = "draw", progress = 0.35 }, 70) })
	end
end

table.insert(views, { name = "mech_rounds", setup = roundsView })
table.insert(views, { name = "mech_bananerang_path", setup = boomerangView })
table.insert(views, { name = "mech_dart_homing", setup = dartView })
table.insert(views, { name = "mech_drumlet_volley", setup = drumletView })
table.insert(views, { name = "mech_patterns", setup = patternsView })

table.insert(views, {
	name = "cleanup",
	setup = function(folder, camera)
		camera.CFrame = CFrame.new(ORIGIN)
	end,
})

return views
