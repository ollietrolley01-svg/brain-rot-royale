-- Bike guns probe (task 22), filmed live: a bot on a bike's pillion and a bot in a car's passenger seat,
-- each behind a driver, each with a target in range out to its side. The real BotService thinks for
-- both (passengerThink); the probe only seats them, as startRide would, and counts where each shot
-- came from.
--
--   python tools/linux/studio.py gallery -Gallery tools/bike_guns_probe.lua -OutDir <dir> -PlaceFile <build> -Record <dir>/x.mp4
--
-- Before task 22 the pillion bot shoots like the car passenger. After it, it gets off ("no hands free")
-- and the car passenger keeps shooting. Run mode starts no client, so the probe draws the shots itself:
-- a yellow line for a shot from a seat, grey for one on foot, and a count over each vehicle.
-- Lines start "[BRR_BikeGuns]". Not shown: a player on the pillion (CombatClient), which needs a Play test.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_BikeGuns] " .. fmt, ...))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(4)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end
local CombatService = mod("CombatService")
local Combatants = mod("Combatants")
local VehicleService = mod("VehicleService")
local ModeTeams = mod("ModeTeams")
local StormService = mod("StormService")
local BotService = mod("BotService")
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))

-- No match: a team mode for the probe's tokens (1 the riders and drivers, 2 the targets), and no storm.
local teamOf = {}
ModeTeams.IsActive = function()
	return true
end
ModeTeams.TeamOf = function(token)
	return teamOf[token]
end
ModeTeams.BaseOf = function()
	return nil
end
StormService.IsOutside = function()
	return false
end
-- What GameMode hands BotService in a team mode (ModeTeams.IsHostile): teammates are left alone.
BotService.IsHostile = function(bot, other)
	return teamOf[bot] ~= teamOf[other]
end
VehicleService.Start()
CombatService.SetEnabled(true)

local C = Vector3.new(-9000, 1600, 3000)
local arena = Instance.new("Model")
arena.Name = "BRR_BikeGunsProbe"
arena.Parent = workspace
local pad = Instance.new("Part")
pad.Anchored = true
pad.Size = Vector3.new(120, 2, 200)
pad.CFrame = CFrame.new(C + Vector3.new(0, -1, -50))
pad.Material = Enum.Material.Asphalt
pad.Color = Color3.fromRGB(70, 70, 75)
pad.Parent = arena

local function board(adornee, size, offset)
	local gui = Instance.new("BillboardGui")
	gui.Size = size
	gui.StudsOffset = offset
	gui.AlwaysOnTop = true
	gui.Adornee = adornee
	gui.Parent = arena
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	label.BackgroundTransparency = 0.15
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = gui
	return label
end

local function rig(name, position)
	for _ = 1, 5 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			model.Name = name
			model.Parent = arena
			model:PivotTo(CFrame.new(position))
			local token = { isBot = true, name = name, character = model }
			Combatants.Register(model, token)
			teamOf[token] = 1
			return model:FindFirstChildOfClass("Humanoid")
		end
		task.wait(0.4)
	end
	error("no rig for " .. name)
end

-- A target per ride, square off its side (a rider's own back blocks a pillion's shot ahead of it):
-- anchored parts and a humanoid that can't die.
local function standIn(name, at)
	local model = Instance.new("Model")
	model.Name = name
	local function limb(partName, size, offset)
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.CFrame = CFrame.new(at + offset)
		p.Anchored = true
		p.Color = Color3.fromRGB(220, 60, 60)
		p.Parent = model
		return p
	end
	local root = limb("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.zero)
	root.Transparency = 1
	limb("Torso", Vector3.new(2, 2, 1), Vector3.zero)
	limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0))
	limb("Legs", Vector3.new(2, 2, 1), Vector3.new(0, -2, 0))
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth, humanoid.Health = 1e6, 1e6
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = arena
	local token = { name = name, character = model }
	Combatants.Register(model, token)
	teamOf[token] = 2
end

-- The two rides, side by side, noses the same way.
local LANES = {
	{ key = "bike", model = "BrrStreetfighter", kind = "bike", x = -6, title = "BIKE PILLION", target = Vector3.new(-28, 3, -2) },
	{ key = "car", model = "TralalaGT", kind = "car", x = 7, title = "CAR PASSENGER", target = Vector3.new(29, 3, -2) },
}
local rows = {}
for _, lane in ipairs(LANES) do
	local vehicle = VehicleService.Create(arena, C + Vector3.new(lane.x, 3, 0), 0, lane.kind, { model = lane.model })
	assert(vehicle, "no " .. lane.model)
	standIn(lane.key .. "Target", C + lane.target)
	local seats = VehicleService.SeatsOf(vehicle)
	local driver = rig(lane.key .. "Driver", seats.driver.Position + Vector3.new(0, 3, 0))
	seats.driver:Sit(driver)
	rows[lane.key] = { lane = lane, vehicle = vehicle, seat = seats.passengers[1], shots = 0, footShots = 0 }
end
task.wait(1.5)

local bots = BotService.Spawn(2, function(i)
	local row = i == 1 and rows.bike or rows.car
	return CFrame.new(row.seat.Position + Vector3.new(0, 3, 0))
end, function() end)
assert(#bots == 2, "bots not spawned")
local byBot = {}
for i, bot in ipairs(bots) do
	local row = i == 1 and rows.bike or rows.car
	teamOf[bot] = 1
	bot.weapon = WeaponData.Get("CrocodiloRifle")
	row.bot = bot
	byBot[bot] = row
	row.seat:Sit(bot.humanoid)
end
task.wait(0.5)
for _, row in pairs(rows) do
	local now = tick()
	-- What Vehicles.startRide leaves for a passenger (pickSeat's "ride" purpose).
	row.bot.ride = { role = "passenger", model = row.vehicle, seat = row.seat, purpose = "ride", boardedAt = now,
		lastTargetAt = now, burstLeft = 0, nextShotAt = 0 }
	say("%s: bot seated %s", row.lane.key, tostring(row.bot.humanoid.SeatPart == row.seat))
	row.label = board(row.vehicle.PrimaryPart or row.seat, UDim2.fromOffset(220, 72), Vector3.new(0, 8, 0))
end

-- Every shot a bot takes goes through BroadcastShot (BotService.shootAt): count it by where the bot sat.
local realBroadcast = CombatService.BroadcastShot
CombatService.BroadcastShot = function(shooter, from, points, ...)
	local row = byBot[shooter]
	if row and points and points[1] then
		local seated = row.bot.humanoid.SeatPart ~= nil
		if seated then
			row.shots += 1
		else
			row.footShots += 1
		end
		local to = points[1]
		local line = Instance.new("Part")
		line.Anchored, line.CanCollide, line.CanQuery, line.CanTouch = true, false, false, false
		line.Material = Enum.Material.Neon
		line.Color = seated and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(160, 160, 160)
		line.Size = Vector3.new(0.4, 0.4, (to - from).Magnitude)
		line.CFrame = CFrame.lookAt((from + to) / 2, to)
		line.Parent = arena
		task.delay(0.25, function()
			line:Destroy()
		end)
	end
	return realBroadcast(shooter, from, points, ...)
end

local function refresh()
	for _, row in pairs(rows) do
		local seated = row.bot.humanoid.SeatPart == row.seat
		row.label.Text = string.format("%s\n%s\nshots from the seat: %d", row.lane.title,
			seated and "bot in the seat" or ("bot got off (" .. tostring(row.bot.lastVehicleExit) .. ")"), row.shots)
		row.label.TextColor3 = row.shots > 0 and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(120, 255, 140)
	end
end

local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = 60
-- Behind and above the two rides, close; the shot lines run out to the targets either side.
local eye, look = C + Vector3.new(0.5, 11, 23), C + Vector3.new(0.5, 2, -4)
local film = RunService.Heartbeat:Connect(function()
	camera.CFrame = CFrame.lookAt(eye, look)
	refresh()
end)
say("film: bots thinking")
BotService.Start()
task.wait(14)
for key, row in pairs(rows) do
	say("%s: shots from the seat %d, on foot %d, still seated %s, last exit %s", key, row.shots, row.footShots,
		tostring(row.bot.humanoid.SeatPart == row.seat), tostring(row.bot.lastVehicleExit))
end
film:Disconnect()
say("done")
return { { name = "end_state", settle = 0.2, hold = 0.5, setup = function(_, cam)
	cam.CFrame = CFrame.lookAt(eye, look)
end } }
