-- Throwables and explosives gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/throwables_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- The Cooked Coconut and the Lowkey Latte at three angles and in a character's hands; the rocket
-- and the 40mm as they fly; a rocket, a 40mm and a frag blast frozen at several ages (ExplosiveFx
-- is paused and stepped by hand, so each frame is exactly the effect at that moment); a smoke
-- cloud filling and full, from outside and from the edge; and the hit splat on a body, a head and a
-- shield. Everything is built high above the map on a plain plate, with a figure for scale.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))
-- Loading WeaponData registers the creative arsenal's round kinds (CreativeRounds) with Ballistics.
require(Shared:WaitForChild("WeaponData"))
local ExplosiveFx = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("ExplosiveFx"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

ExplosiveFx.Paused = true

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = Vector3.new(0, 1400, -3400)
local V = Vector3.new

local views = {}
local function add(name, setup, hold)
	table.insert(views, { name = name, settle = 1.2, hold = hold or 2, setup = setup })
end

local function block(parent, name, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Color = color or Color3.fromRGB(150, 148, 144)
	part.Material = material or Enum.Material.Concrete
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- A plate to blow things up on, with a low wall and a figure for scale.
local function stage(folder, centre)
	block(folder, "Ground", V(120, 2, 120), centre - V(0, 1, 0), Color3.fromRGB(132, 128, 120))
	block(folder, "Wall", V(14, 6, 1), centre + V(0, 3, -14), Color3.fromRGB(170, 160, 140), Enum.Material.Brick)
	local figure = Instance.new("Model")
	figure.Name = "Figure"
	block(figure, "Body", V(2, 3.2, 1), centre + V(9, 1.6, 4), Color3.fromRGB(80, 110, 160), Enum.Material.SmoothPlastic)
	block(figure, "Head", V(1.2, 1.2, 1.2), centre + V(9, 3.8, 4), Color3.fromRGB(230, 200, 170), Enum.Material.SmoothPlastic)
	block(figure, "Legs", V(2, 2, 1), centre + V(9, -0.2 + 1, 4), Color3.fromRGB(60, 60, 70), Enum.Material.SmoothPlastic)
	figure.Parent = folder
end

local function frameFor(model, direction, fov)
	local box, size = model:GetBoundingBox()
	local radius = size.Magnitude / 2
	return CFrame.lookAt(box.Position + direction.Unit * radius / math.tan(math.rad(fov / 2)) * 1.08, box.Position)
end

local function advanceTo(seconds)
	local step = 1 / 60
	local t = 0
	while t < seconds - 1e-6 do
		local dt = math.min(step, seconds - t)
		ExplosiveFx.Advance(dt)
		t += dt
	end
end

--------------------------------------------------------------------------------
-- The models
--------------------------------------------------------------------------------

local ANGLES = { V(0.2, 0.3, -1), V(1, 0.45, 0.4), V(-0.6, 0.95, 0.6) }

for _, id in ipairs({ "CookedCoconut", "LowkeyLatte", "ClingyCrumpet" }) do
	for side, direction in ipairs(ANGLES) do
		add(string.format("model_%s_%d", id, side), function(folder, camera)
			ExplosiveFx.Clear()
			local model = ItemModels.Build(id, { scale = 2.5 })
			model:PivotTo(CFrame.new(HIGH))
			model.Parent = folder
			local parts = 0
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					parts += 1
				end
			end
			note(string.format("%s: %d parts, built through ItemModels.Build", id, parts))
			camera.FieldOfView = 30
			camera.CFrame = frameFor(model, direction, 30)
		end)
	end
end

-- On the floor as a real pickup (LootService's own drop: the pad, the label, the 1.25 pickup scale),
-- close, so the husk and the cup read the way a player finds them.
for _, id in ipairs({ "CookedCoconut", "LowkeyLatte", "ClingyCrumpet" }) do
	add("floor_" .. id, function(folder, camera)
		ExplosiveFx.Clear()
		local LootService = require(modules:WaitForChild("LootService"))
		local at = HIGH + V(20, 0, -40)
		block(folder, "Ground", V(30, 2, 30), at - V(0, 1, 0), Color3.fromRGB(132, 128, 120))
		local ok, err = pcall(function()
			LootService.DropItem(id, at + V(0, 1, 0), 2)
		end)
		local pickup = nil
		local loot = workspace:FindFirstChild("Loot")
		if loot then
			for _, d in ipairs(loot:GetDescendants()) do
				if d:IsA("BasePart") and d:GetAttribute("ItemId") == id then
					pickup = d
					break
				end
			end
		end
		note(string.format("floor %s: dropped ok=%s%s, pickup %s", id, tostring(ok), ok and "" or (" " .. tostring(err)), pickup and "found" or "missing"))
		local focus = pickup and pickup.Position + V(0, 1.3, 0) or at + V(0, 1.3, 0)
		camera.FieldOfView = 30
		camera.CFrame = CFrame.lookAt(focus + V(3.2, 2.2, -4.6), focus)
		task.delay(6, function()
			pcall(LootService.Clear)
		end)
	end, 3)
end

-- Held, through the same mount every item uses.
local function character()
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		return rig
	end
	return nil
end

for _, id in ipairs({ "CookedCoconut", "LowkeyLatte", "ClingyCrumpet" }) do
	add("held_" .. id, function(folder, camera)
		ExplosiveFx.Clear()
		local WeaponService = require(modules:WaitForChild("WeaponService"))
		local rig = character()
		if not rig then
			note("held_" .. id .. ": no rig in edit mode")
			return
		end
		local at = HIGH + V(40, 0, 0)
		rig:PivotTo(CFrame.new(at))
		rig.Parent = folder
		local model, body = ItemModels.Build(id, { anchored = false, name = "HeldItem" })
		local mounted = WeaponService.MountGun(rig, model, body)
		note(string.format("held_%s mounted: %s", id, tostring(mounted)))
		camera.FieldOfView = 40
		camera.CFrame = CFrame.lookAt(at + V(2.2, 1.2, -6.5), at + V(0.6, 0.6, 0))
	end)
end

--------------------------------------------------------------------------------
-- Blood in the colour of the gun's rank (Oliver, 2026-09-18)
--------------------------------------------------------------------------------

-- One hit per rarity across a dark chest plate, labelled, the way HitSplatClient draws them from
-- the rank the server sends with each hit.
add("splat_rarities", function(folder, camera)
	ExplosiveFx.Clear()
	local Rarity = require(Shared:WaitForChild("Rarity"))
	local centre = HIGH + V(120, 0, 200)
	local chest = block(folder, "Chest", V(17, 4, 1), centre + V(0, 3, 0), Color3.fromRGB(28, 30, 36))
	for index, name in ipairs(Rarity.Order) do
		local x = -6.9 + (index - 1) * 2.3
		ExplosiveFx.Splat(chest, centre + V(x, 3.3, -0.5), V(0, 0, -1), { color = Rarity.Color(name) })
		local anchor = Instance.new("Part")
		anchor.Anchored = true
		anchor.Transparency = 1
		anchor.CanCollide = false
		anchor.CanQuery = false
		anchor.Size = V(0.1, 0.1, 0.1)
		anchor.Position = centre + V(x, 0.6, -0.5)
		anchor.Parent = folder
		local gui = Instance.new("BillboardGui")
		gui.Size = UDim2.fromOffset(120, 24)
		gui.AlwaysOnTop = true
		gui.Parent = anchor
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.Font = Enum.Font.GothamBold
		text.TextSize = 14
		text.TextColor3 = Rarity.Color(name)
		text.TextStrokeTransparency = 0.3
		text.Text = name
		text.Parent = gui
	end
	advanceTo(0.5)
	note("splat_rarities: seven splats, one per rank, on one plate")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(centre + V(0, 3.2, -13.5), centre + V(0, 2.6, 0))
end)

--------------------------------------------------------------------------------
-- The Clingy Crumpet stuck, armed, and its placement ghost
--------------------------------------------------------------------------------

-- Stuck to a wall and to the figure's chest, placed exactly as ProjectileClient places a live one
-- (Ballistics.StuckFrame at the contact point), the timer lit as in its last half-second; then the
-- ghost StickyPreview shows while one is in hand: green on the wall it will stick to, red where the
-- throw meets nothing.
local crumpetSpec = Ballistics.Throwables.ClingyCrumpet
local function stuckView(name, place)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local centre = HIGH + V(800, 0, 0)
		stage(folder, centre)
		local wall = block(folder, "StickWall", V(1, 8, 10), centre + V(-6, 4, -2), Color3.fromRGB(170, 160, 140), Enum.Material.Brick)
		place(folder, camera, centre, wall)
	end)
end
local function stuckModel(folder, surfacePoint, normal, lit)
	local model = ItemModels.Build("ClingyCrumpet", { name = "BRR_Thrown" })
	model:PivotTo(Ballistics.StuckFrame(surfacePoint, normal, crumpetSpec and crumpetSpec.stickOffset or 0))
	model.Parent = folder
	if lit then
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "Glow" then
				part.Color = Color3.fromRGB(255, 250, 220)
			end
		end
	end
	local count = 0
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			count += 1
		end
	end
	return model, count
end
local function ghostView(folder, camera, point, normal, valid)
	local StickyPreview = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("StickyPreview"))
	StickyPreview.Hide()
	StickyPreview.Show("ClingyCrumpet", point, normal, valid)
	local ghost = StickyPreview.Model()
	if ghost then
		ghost.Parent = folder
	end
	note(string.format("sticky ghost %s: %s", valid and "valid" or "invalid", ghost and "shown" or "missing"))
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(point + V(5, 2.5, 4), point)
end
stuckView("sticky_on_wall", function(folder, camera, centre, wall)
	local point = wall.Position + V(0.5, 0.5, 1)
	local _, count = stuckModel(folder, point, V(1, 0, 0), false)
	note(string.format("sticky on wall: %d parts, StuckFrame on the wall's +X face", count))
	camera.FieldOfView = 35
	camera.CFrame = CFrame.lookAt(point + V(3.2, 1.4, 2.6), point)
end)
stuckView("sticky_on_figure_armed", function(folder, camera, centre)
	-- The figure's chest: the Body block at centre + (9, 1.6, 4), 2 wide and 1 deep; its -Z face.
	local point = centre + V(9, 2.1, 3.5)
	stuckModel(folder, point, V(0, 0, -1), true)
	camera.FieldOfView = 35
	camera.CFrame = CFrame.lookAt(point + V(-2.4, 1.0, -3.0), point)
end)
stuckView("sticky_ghost_valid", function(folder, camera, centre, wall)
	ghostView(folder, camera, wall.Position + V(0.5, 1, -1), V(1, 0, 0), true)
end)
stuckView("sticky_ghost_invalid", function(folder, camera, centre)
	ghostView(folder, camera, centre + V(12, 6, 12), V(0, 1, 0), false)
end)

-- Rounds in flight, big in frame (no trail here: a trail on something standing still piles up).
for _, kind in ipairs({ "rocket", "grenade" }) do
	add("round_" .. kind, function(folder, camera)
		ExplosiveFx.Clear()
		local model = ThrowableModels.Round(kind, 1)
		model:PivotTo(CFrame.lookAt(HIGH + V(-40, 0, 0), HIGH + V(-40, 0, -10)))
		model.Parent = folder
		local _, size = model:GetBoundingBox()
		note(string.format("round %s: %.2f x %.2f x %.2f studs", kind, size.X, size.Y, size.Z))
		camera.FieldOfView = 30
		camera.CFrame = frameFor(model, V(0.8, 0.35, -0.6), 30)
	end)
end

-- The creative arsenal's rounds, drawn from their `look` (no hand-built model): each at rest, close,
-- and as it flies, oriented by its spin the way ProjectileClient orients it.
for _, kind in ipairs({ "ricochetDisc", "homingSlipper", "lobbedToast" }) do
	local spec = Ballistics.Rounds[kind]
	if spec then
		add("look_" .. kind, function(folder, camera)
			ExplosiveFx.Clear()
			local model = ThrowableModels.Round(kind, 1)
			model:PivotTo(CFrame.new(HIGH + V(-80, 0, 0)))
			model.Parent = folder
			local parts = 0
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					parts += 1
				end
			end
			local _, size = model:GetBoundingBox()
			note(string.format("look %s (%s, spin %s): %d parts, %.2f x %.2f x %.2f studs", kind, spec.look and spec.look.shape or "?",
				ThrowableModels.SpinOf(kind), parts, size.X, size.Y, size.Z))
			camera.FieldOfView = 30
			camera.CFrame = frameFor(model, V(0.7, 0.5, -0.7), 30)
		end)
		add("look_" .. kind .. "_flying", function(folder, camera)
			ExplosiveFx.Clear()
			local at = HIGH + V(-80, 0, 40)
			local velocity = V(-0.4, -0.15, -1).Unit * spec.speed
			local model = ThrowableModels.Round(kind, 1)
			model:PivotTo(Ballistics.RoundOrientation(ThrowableModels.SpinOf(kind), at, velocity, 1.1))
			model.Parent = folder
			-- A ground plate under it for the horizon, and a figure for scale.
			block(folder, "Ground", V(60, 2, 60), at - V(0, 5, 0), Color3.fromRGB(132, 128, 120))
			block(folder, "Figure", V(2, 5, 1), at + V(-6, -1.5, -8), Color3.fromRGB(80, 110, 160), Enum.Material.SmoothPlastic)
			camera.FieldOfView = 40
			camera.CFrame = CFrame.lookAt(at + V(5, 2, 3), at + velocity.Unit * 2)
		end)
	end
end

-- A rocket that has actually flown: moved along its line for a third of a second at speed, so the
-- trail is laid out behind it the way it is in a match, then held for the capture.
add("round_rocket_flying", function(folder, camera)
	ExplosiveFx.Clear()
	local model = ThrowableModels.Round("rocket", 1)
	local from = HIGH + V(-40, 0, 60)
	local direction = V(0, 0, -1)
	model:PivotTo(CFrame.lookAt(from, from + direction))
	model.Parent = folder
	ExplosiveFx.Trail(model.PrimaryPart, V(0, 0, 1.5))
	local speed = 200
	local travelled = 0
	local started = os.clock()
	while os.clock() - started < 0.35 do
		local dt = task.wait()
		travelled += speed * dt
		model:PivotTo(CFrame.lookAt(from + direction * travelled, from + direction * (travelled + 1)))
	end
	local at = from + direction * travelled
	camera.FieldOfView = 45
	camera.CFrame = CFrame.lookAt(at + V(9, 3, 6), at + direction * -4)
end)

--------------------------------------------------------------------------------
-- Blasts frozen at several ages
--------------------------------------------------------------------------------

local function blastView(kind, radius, age, direction, fov)
	add(string.format("blast_%s_t%03d", kind, math.floor(age * 100)), function(folder, camera)
		ExplosiveFx.Clear()
		local centre = HIGH + V(200, 0, 0)
		stage(folder, centre)
		ExplosiveFx.Explosion(centre, Vector3.yAxis, kind, radius)
		advanceTo(age)
		local live, debris = ExplosiveFx.Count()
		note(string.format("blast %s r%d at %.2fs: %d live effects, %d debris", kind, radius, age, live, debris))
		camera.FieldOfView = fov or 60
		camera.CFrame = CFrame.lookAt(centre + direction, centre + V(0, radius * 0.35, 0))
	end)
end

for _, age in ipairs({ 0.06, 0.16, 0.3, 0.55, 0.9 }) do
	blastView("rocket", 14, age, V(24, 11, 30), 60)
end
blastView("rocket", 14, 0.3, V(4, 2.5, 14), 75)
blastView("grenade", 11, 0.25, V(20, 9, 26), 60)
blastView("frag", 13, 0.25, V(20, 9, 26), 60)
blastView("frag", 13, 0.6, V(20, 9, 26), 60)
add("blast_scorch_after", function(folder, camera)
	ExplosiveFx.Clear()
	local centre = HIGH + V(200, 0, 0)
	stage(folder, centre)
	ExplosiveFx.Explosion(centre, Vector3.yAxis, "rocket", 14)
	advanceTo(4)
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(centre + V(18, 14, 22), centre)
end)

-- Off the ground. A rocket that struck the figure's chest (the server's normal is the figure's
-- face): with the old rule the scorch and the shock ring stood on that face, a black disc in the
-- air; now they lie on the ground under the blast. Then a real airburst twelve studs up, which
-- marks nothing. The note counts the scorch parts and says where the scorch is facing.
local function countScorches()
	local count, facing = 0, "none"
	for _, child in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if child.Name == "Scorch" then
			count += 1
			local axis = child.CFrame.RightVector
			facing = string.format("axis (%.1f, %.1f, %.1f) at y %.1f", axis.X, axis.Y, axis.Z, child.Position.Y)
		end
	end
	return count, facing
end
local function airburstView(name, trustNormal, height, normal)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local centre = HIGH + V(200, 0, 0)
		stage(folder, centre)
		local at = centre + V(8, height, 4)
		ExplosiveFx.TrustNormal = trustNormal
		ExplosiveFx.Explosion(at, normal, "rocket", 14)
		ExplosiveFx.TrustNormal = false
		advanceTo(1.2)
		local count, facing = countScorches()
		note(string.format("%s: blast at %.1f up, normal %s: %d scorch, %s (plate top at y %.1f)", name, height, normal and "figure's face" or "none", count, facing, centre.Y))
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(at + V(-19, 8, 15), centre + V(8, 2, 4))
	end)
end
airburstView("blast_airburst_figure_before", true, 2.2, V(-1, 0, 0))
airburstView("blast_airburst_figure_after", false, 2.2, V(-1, 0, 0))
airburstView("blast_airburst_high_after", false, 12, nil)

-- Upstairs (Oliver, 2026-09-18: "what about when it's on the second story of a building and
-- destroys the floor under it"): a blast on a floor slab 12 up leaves its mark on that slab, not
-- on the ground below; when the slab is destroyed the mark goes with it, the same frame; and a
-- mark on a wide moving part (a vehicle's body) rides with it.
local function upperFloorView(name, act)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local centre = HIGH + V(200, 0, 0)
		stage(folder, centre)
		local slab = block(folder, "UpperFloor", V(22, 1, 22), centre + V(-30, 12, 0), Color3.fromRGB(150, 140, 128), Enum.Material.Concrete)
		for _, corner in ipairs({ V(-10, 0, -10), V(10, 0, -10), V(-10, 0, 10), V(10, 0, 10) }) do
			block(folder, "Post", V(1, 12, 1), centre + V(-30, 6, 0) + corner, Color3.fromRGB(110, 104, 98))
		end
		ExplosiveFx.Explosion(centre + V(-30, 12.5, 0), Vector3.yAxis, "rocket", 14)
		act(slab, folder, centre)
		local count, facing = countScorches()
		note(string.format("%s: %d scorch, %s (slab top at y %.1f, ground at %.1f)", name, count, facing, centre.Y + 12.5, centre.Y))
		camera.FieldOfView = 55
		camera.CFrame = CFrame.lookAt(centre + V(-30, 12.5, 0) + V(24, 9, 26), centre + V(-30, 7, 0))
	end)
end
upperFloorView("scorch_upper_floor", function()
	advanceTo(1.4)
end)
upperFloorView("scorch_floor_destroyed", function(slab, folder, centre)
	advanceTo(1.2)
	-- The slab breaks: its part goes, and chunks of it are caught mid-fall.
	slab:Destroy()
	local rng = Random.new(7)
	for index = 1, 7 do
		block(folder, "Chunk", V(rng:NextNumber(2, 5), 1, rng:NextNumber(2, 5)),
			CFrame.new(centre + V(-30 + rng:NextNumber(-8, 8), 12.5 - index * 1.3, rng:NextNumber(-8, 8))) * CFrame.Angles(rng:NextNumber(-0.6, 0.6), rng:NextNumber(0, 3), rng:NextNumber(-0.6, 0.6)),
			Color3.fromRGB(150, 140, 128), Enum.Material.Concrete)
	end
	advanceTo(0.2)
end)
add("scorch_vehicle_rides", function(folder, camera)
	ExplosiveFx.Clear()
	local centre = HIGH + V(200, 0, 0)
	stage(folder, centre)
	local body = block(folder, "VehicleBody", V(12, 2, 6), centre + V(-20, 2, 20), Color3.fromRGB(200, 60, 50), Enum.Material.Metal)
	ExplosiveFx.Explosion(centre + V(-20, 3, 20), Vector3.yAxis, "grenade", 11)
	advanceTo(1.4)
	body.CFrame = body.CFrame + V(0, 0, 14)
	advanceTo(0.1)
	local count, facing = countScorches()
	note(string.format("scorch_vehicle_rides: body moved (0, 0, 14) after the blast; %d scorch, %s (body top now at z %.1f)", count, facing, body.Position.Z))
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(centre + V(-20, 3, 34) + V(14, 9, 10), centre + V(-20, 2, 27))
end)

--------------------------------------------------------------------------------
-- The Brainrot Fortress hatch (Oliver, 2026-09-18: "the roof is inaccessible")
--------------------------------------------------------------------------------

-- The roof is reached up the truss through the hatch in the second floor. The note measures the
-- opening in front of the truss's climbing face at floor height (a body on a truss stands about a
-- stud off the rungs, so anything under ~2 studs stops the climb at the top) and the headroom above
-- the hatch; the frames look down into the hatch and up at it from the ground floor.
local function fortressView(name, place)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local DefenseService = require(modules:WaitForChild("DefenseService"))
		local centre = HIGH + V(600, 0, 0)
		block(folder, "Ground", V(60, 2, 60), centre - V(0, 1, 0), Color3.fromRGB(132, 128, 120))
		local model = DefenseService.Build("BrainrotFortress", CFrame.new(centre), nil)
		model.Parent = folder
		-- The structure rises out of the ground over RISE_TIME; measure it once it has stood up
		-- (measured too early, the floor wasn't there to hit and the opening read as 8, "nothing").
		task.wait(1.2)
		local truss = model:FindFirstChildWhichIsA("TrussPart")
		if truss then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { truss }
			local face = truss.Position - V(truss.Size.X / 2, 0, 0)
			local level = V(face.X, centre.Y + 8.3, face.Z)
			local across = workspace:Raycast(level, V(-8, 0, 0), params)
			local opening = across and (level - across.Position).Magnitude or 8
			local above = workspace:Raycast(V(face.X - 1, centre.Y + 8.6, face.Z), V(0, 8, 0), params)
			local headroom = above and (above.Position.Y - (centre.Y + 8.6)) or 8
			note(string.format("%s: truss at x %+.1f, climbing face x %+.1f; opening in front of it at floor height %.1f studs (to %s); headroom over the hatch %s",
				name, truss.Position.X - centre.X, face.X - centre.X, opening, across and across.Instance.Name or "nothing within 8",
				above and string.format("%.1f (%s)", headroom, above.Instance.Name) or "clear for 8"))
		else
			note(name .. ": no TrussPart in the fortress")
		end
		place(camera, centre)
	end)
end
fortressView("fortress_hatch_top", function(camera, centre)
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(centre + V(6, 30, 14), centre + V(0, 8.3, 0))
end)
fortressView("fortress_hatch_inside", function(camera, centre)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(centre + V(-6, 2.5, 7), centre + V(0, 8.3, 0))
end)

--------------------------------------------------------------------------------
-- Smoke
--------------------------------------------------------------------------------

local function smokeView(name, elapsed, direction, fov)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local centre = HIGH + V(400, 0, 0)
		stage(folder, centre)
		-- Something behind the cloud, to show it hides things.
		block(folder, "Behind", V(3, 6, 3), centre + V(0, 3, 26), Color3.fromRGB(220, 60, 60), Enum.Material.Neon)
		local spec = Ballistics.Throwables.LowkeyLatte
		local cup = ItemModels.Build("LowkeyLatte", {})
		cup:PivotTo(CFrame.new(centre + V(0, 0.75, 0)) * CFrame.Angles(0, 0.4, 0))
		cup.Parent = folder
		local cloud = ExplosiveFx.Cloud(centre + V(0, 0.5, 0), spec, 0)
		advanceTo(elapsed)
		note(string.format("%s: elapsed %.1fs, radius %.1f, density %.2f", name, elapsed, cloud.radius, cloud.density))
		camera.FieldOfView = fov or 60
		camera.CFrame = CFrame.lookAt(centre + direction, centre + V(0, 4, 0))
	end)
end

smokeView("smoke_t1", 1.0, V(0, 10, -50), 60)
smokeView("smoke_t3", 3.0, V(0, 10, -50), 60)
smokeView("smoke_t8_low", 8.0, V(30, 3, -30), 65)
smokeView("smoke_t8_high", 8.0, V(0, 40, -40), 60)
smokeView("smoke_fading", 19.0, V(0, 10, -50), 60)

--------------------------------------------------------------------------------
-- Splats
--------------------------------------------------------------------------------

local function splatView(name, options, limbName, direction)
	add(name, function(folder, camera)
		ExplosiveFx.Clear()
		local rig = character()
		local at = HIGH + V(600, 0, 0)
		if not rig then
			note(name .. ": no rig in edit mode")
			return
		end
		rig:PivotTo(CFrame.new(at))
		rig.Parent = folder
		local limb = rig:FindFirstChild(limbName)
		if not limb then
			note(name .. ": no " .. limbName)
			return
		end
		-- A hit from the front, a little off centre.
		local from = limb.Position + V(0.3, 0.2, -6)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { rig }
		local hit = workspace:Raycast(from, (limb.Position + V(0.15, 0.1, 0) - from) * 1.5, params)
		if not hit then
			note(name .. ": trace missed the limb")
			return
		end
		ExplosiveFx.Splat(hit.Instance, hit.Position, hit.Normal, options)
		advanceTo(0.12)
		note(string.format("%s on %s at %.2f,%.2f,%.2f", name, hit.Instance.Name, hit.Position.X - at.X, hit.Position.Y - at.Y, hit.Position.Z - at.Z))
		camera.FieldOfView = 30
		camera.CFrame = CFrame.lookAt(limb.Position + direction, limb.Position)
	end)
end

splatView("splat_body", {}, "UpperTorso", V(1.2, 0.8, -4.5))
splatView("splat_body_far", {}, "UpperTorso", V(2, 1, -9))
splatView("splat_head", { headshot = true }, "Head", V(0.8, 0.5, -3.2))
splatView("splat_shield", { shield = true }, "UpperTorso", V(1.2, 0.8, -4.5))

return views
