-- Parachute gallery, for tools/gallery.ps1 (run it in the background: it waits on the Studio lock):
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/parachute_gallery.lua -OutDir <folder> -TimeoutSeconds 1500 [-PlaceFile <rbxlx>]
--
-- Every canopy in Shared/ParachuteModels at the worn scale, high in the sky so the sky is behind it:
--   eye     from the pilot's eye under it, looking up (where a slit shows as light)
--   ground  from far below and to one side, the way other players see a drop-in
--   front   from in front, a little above and to one side
--   side    straight from the side
--   above   from above
--   rig     hung over an R15 character exactly as MovementService.attachCanopy hangs the default
--           one (the bar 1.4 studs over the head, welded), from behind and above like the
--           third-person camera
-- then a line-up of all of them and a sky full of them, as a drop-in looks from the ground.
-- Set ONLY to a design id to render just that one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ParachuteModels = require(Shared:WaitForChild("ParachuteModels"))

local ONLY = nil
local SCALE = ParachuteModels.WornScale
local HIGH = Vector3.new(0, 1400, -3000)
local V = Vector3.new

local views = {}
local function add(name, setup, hold)
	table.insert(views, { name = name, settle = 1.2, hold = hold or 2, setup = setup })
end

local function canopy(id, folder, at)
	local model = ParachuteModels.Build(id, { scale = SCALE })
	model:PivotTo(at)
	model.Parent = folder
	return model
end

-- An R15 character, or a stand-in with a root and a head if edit mode won't make one.
local function character()
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig
	end
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = V(2, 2, 1)
	root.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = V(1.2, 1.2, 1.2)
	head.CFrame = CFrame.new(0, 2.6, 0)
	head.Parent = model
	model.PrimaryPart = root
	return model
end

local movementLoaded, MovementService = pcall(function()
	return require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("MovementService"))
end)
if not movementLoaded then
	print("[BRR_Gallery] note MovementService didn't load, so rigs get their canopy attached by hand: " .. tostring(MovementService))
end

-- A character standing at `at` with `id`'s canopy over it, through the real drop-in path: a bot's
-- drop (MovementService.BotDrop -> attachCanopy -> ParachuteFor -> ParachuteModels.Build). If that
-- can't run here, the canopy is attached by hand exactly as attachCanopy does it.
local function rigWith(id, folder, at)
	local rig = character()
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	rig:PivotTo(at)
	rig.Parent = folder
	if movementLoaded then
		MovementService.ParachuteFor = function()
			return id
		end
		local ok, dropped = pcall(MovementService.BotDrop, rig, at.Position - V(0, 500, 0), function() end)
		local worn = rig:FindFirstChild("GliderCanopy")
		if ok and dropped and worn and worn:GetAttribute("ParachuteId") == id then
			return rig
		end
		print(string.format("[BRR_Gallery] note BotDrop didn't hang %s (ok %s, dropped %s, canopy %s); attaching by hand", id, tostring(ok),
			tostring(dropped), worn and tostring(worn:GetAttribute("ParachuteId")) or "none"))
		if worn then
			worn:Destroy()
		end
	end
	local head = rig:FindFirstChild("Head")
	local root = rig:FindFirstChild("HumanoidRootPart")
	local model, body = ParachuteModels.Build(id, { scale = SCALE, anchored = false, name = "GliderCanopy" })
	model:PivotTo(CFrame.new(head.Position + V(0, 1.4, 0)) * root.CFrame.Rotation)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = head
	weld.Parent = body
	body.Anchored = true
	model.Parent = rig
	return rig
end

for _, id in ipairs(ParachuteModels.Order) do
	if not ONLY or id == ONLY then
		local centre = CFrame.new(HIGH)
		add(id .. "_eye", function(folder, camera)
			canopy(id, folder, centre)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt(HIGH + V(0.5, -1.5, -3.5), HIGH + V(0, 7.8, 0))
		end)
		add(id .. "_ground", function(folder, camera)
			canopy(id, folder, centre)
			camera.FieldOfView = 30
			camera.CFrame = CFrame.lookAt(HIGH + V(12, -42, -20), HIGH + V(0, 4.5, 0))
		end)
		add(id .. "_front", function(folder, camera)
			canopy(id, folder, centre)
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(HIGH + V(9, 11, -17), HIGH + V(0, 4.2, 0))
		end)
		add(id .. "_side", function(folder, camera)
			canopy(id, folder, centre)
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(HIGH + V(-19, 5, -1.5), HIGH + V(0, 4.5, 0))
		end)
		add(id .. "_above", function(folder, camera)
			canopy(id, folder, centre)
			camera.FieldOfView = 55
			camera.CFrame = CFrame.lookAt(HIGH + V(3, 21, 9), HIGH + V(0, 6, 0))
		end)
		add(id .. "_rig", function(folder, camera)
			local at = CFrame.new(HIGH + V(80, 0, 0))
			rigWith(id, folder, at)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt(at.Position + V(5, 7, 15), at.Position + V(0, 4, 0))
		end)
	end
end

-- All of them in a row of rows, from in front and above.
add("lineup", function(folder, camera)
	local columns = 5
	for index, id in ipairs(ParachuteModels.Order) do
		local column = (index - 1) % columns
		local row = (index - 1) // columns
		canopy(id, folder, CFrame.new(HIGH + V(-400 + column * 17, row * -11, row * 14)))
	end
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(HIGH + V(-366, 24, -56), HIGH + V(-366, -6, 14))
end, 3)

-- The crate reveal's size, the way claude-f5's reveal builds a prize: measured at scale 1, rebuilt so
-- its longest side is 5.5 studs, centred. Two rows, turned a little to show the top.
add("reveal_size", function(folder, camera)
	for index, id in ipairs(ParachuteModels.Order) do
		local measured = ParachuteModels.Build(id, { scale = 1 })
		local _, size = measured:GetBoundingBox()
		measured:Destroy()
		local model = ParachuteModels.Build(id, { scale = 5.5 / math.max(size.X, size.Y, size.Z) })
		local box = model:GetBoundingBox()
		model.WorldPivot = box
		local column = (index - 1) % 8
		local row = (index - 1) // 8
		model:PivotTo(CFrame.new(HIGH + V(-800 + column * 7, -row * 6, row * 5)) * CFrame.Angles(0.35, 0.5, 0))
		model.Parent = folder
	end
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(HIGH + V(-775.5, 6, -30), HIGH + V(-775.5, -3, 3))
end, 3)

-- A drop-in: every canopy over a character, spread through the sky, from the ground looking up.
add("dropin_sky", function(folder, camera)
	local random = Random.new(7)
	for index, id in ipairs(ParachuteModels.Order) do
		local offset = V(random:NextNumber(-60, 60), random:NextNumber(20, 90), random:NextNumber(20, 150))
		local at = CFrame.new(HIGH + V(400, 0, 0) + offset) * CFrame.Angles(0, random:NextNumber(-0.8, 0.8), 0)
		rigWith(id, folder, at)
	end
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(HIGH + V(400, -30, -20), HIGH + V(400, 50, 90))
end, 3)

return views
