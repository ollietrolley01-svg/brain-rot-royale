-- Bot rider probe (task 21): does a bot engage someone sitting in a vehicle? Run mode, real vehicles,
-- real BotService, real physics. tools/bot_rider_sight_check.py proves the same sight rule in lupa
-- against boxes; this is the real car geometry.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/bot_rider_probe.lua -WaitSeconds 240
--
-- Each case gets its own pad high over the void, 700 studs from the next (past bot vision): a parked
-- vehicle, a stand-in rider seated in it (a rig registered with Combatants, so it neither moves nor
-- shoots back), and a rifle bot anchored side-on to it, facing it. For ROUND_SECONDS the probe samples
-- whether the bot's target is the rider and counts the bot's shots and the damage that reaches the
-- rider and the vehicle. Damage to both is counted and NOT applied, so the car isn't wrecked mid-case.
--
-- Vehicle seat-seeking is off for the bot (bot.noVehicleUntil) except in the two "seat-seeking on" cases,
-- because a bot on foot within BotBoardReach of an armed car walks to its free gun seat before it looks
-- for a target, and an anchored bot never gets there (reported in PR, not changed here).
--
-- Lines start "[BRR_Rider]". Expected with task 21: the car driver, the pickup's bed rider and the
-- armoured car's gunner are targeted and hit; the armoured car's driver is not (sealed cabin); the
-- car driver behind a wall is not; the rider on foot is (control).

local ROUND_SECONDS = 20
local PAD_Y = 1600
local PAD_X = 9000

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_Rider] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end
local CombatService = mod("CombatService")
local Combatants = mod("Combatants")
local VehicleService = mod("VehicleService")
local BotService = mod("BotService")
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local VehicleCover = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VehicleCover"))

VehicleService.Start()
CombatService.SetEnabled(true)

local arena = Instance.new("Model")
arena.Name = "BRR_RiderProbeArena"
arena.Parent = workspace
local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Concrete
	part.Parent = arena
	return part
end

-- Taps: counted, not applied, for the probe's own tokens only.
local riders, shooters = {}, {}
local tally = {}
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, ...)
	local row = shooters[attacker]
	if row and victim == row.token then
		row.riderHits += 1
		row.riderDamage += amount
		return amount
	end
	return realDeal(attacker, victim, amount, ...)
end
local realVehicle = CombatService.DamageVehicle
CombatService.DamageVehicle = function(attacker, model, amount, ...)
	local row = shooters[attacker]
	if row and model == row.vehicle then
		row.vehicleDamage += amount
		return
	end
	return realVehicle(attacker, model, amount, ...)
end
local realBroadcast = CombatService.BroadcastShot
CombatService.BroadcastShot = function(shooter, ...)
	local row = shooters[shooter]
	if row then
		row.shots += 1
	end
	return realBroadcast(shooter, ...)
end

-- A stand-in rider: root, torso, head and a humanoid, registered as a combatant.
local function standIn(name, position)
	local model = Instance.new("Model")
	model.Name = name
	local function limb(partName, size, offset)
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.CFrame = CFrame.new(position + offset)
		p.Parent = model
		return p
	end
	local root = limb("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.zero)
	root.Transparency = 1
	local torso = limb("Torso", Vector3.new(2, 2, 1), Vector3.zero)
	local head = limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0))
	for _, p in ipairs({ torso, head }) do
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1 = root, p
		weld.Parent = root
		p.Massless = true
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = arena
	local token = { name = name, character = model }
	Combatants.Register(model, token)
	return token, model, humanoid, root
end

local function sit(humanoid, root, seat)
	root.CFrame = seat.CFrame + Vector3.new(0, 2, 0)
	pcall(function()
		seat:Sit(humanoid)
	end)
	for _ = 1, 30 do
		if humanoid.SeatPart == seat then
			return true
		end
		task.wait()
	end
	return false
end

-- `seek`: the bot may go for a vehicle's free seat (Vehicles.considerVehicle, which runs before findTarget
-- and holds the bot for the whole walk). Off everywhere else, so a case measures sight and targeting only.
local CASES = {
	{ name = "Rotster driver, side 40", model = "Rotster", seat = "DriverSeat", range = 40 },
	{ name = "Rotster driver, side 40, seat-seeking on", model = "Rotster", seat = "DriverSeat", range = 40, seek = true },
	{ name = "Rotster driver, side 120", model = "Rotster", seat = "DriverSeat", range = 120 },
	{ name = "Rotster driver, front 40", model = "Rotster", seat = "DriverSeat", range = 40, front = true },
	{ name = "CrocodiloRanger bed, side 40", model = "CrocodiloRanger", seat = "PassengerSeat2", range = 40 },
	{ name = "CrocodiloRanger bed, side 40, seat-seeking on", model = "CrocodiloRanger", seat = "PassengerSeat2", range = 40, seek = true },
	{ name = "TartarugaScout driver, side 40", model = "TartarugaScout", seat = "DriverSeat", range = 40 },
	{ name = "TartarugaScout gunner, side 40", model = "TartarugaScout", seat = "GunnerSeat", range = 40 },
	{ name = "Rotster driver behind a wall, side 40", model = "Rotster", seat = "DriverSeat", range = 40, wall = true },
	{ name = "on foot, 40 (control)", range = 40 },
}

local rows = {}
for index, case in ipairs(CASES) do
	local ok, err = pcall(function()
		local c = Vector3.new(PAD_X + index * 700, PAD_Y, 0)
		block("Pad" .. index, Vector3.new(300, 2, 300), CFrame.new(c - Vector3.new(0, 1, 0)))
		local row = { case = case, boarding = 0, samples = 0, targeted = 0, shots = 0, riderHits = 0, riderDamage = 0, vehicleDamage = 0 }
		local token, model, humanoid, root = standIn("Rider" .. index, c + Vector3.new(0, 3, 0))
		humanoid.MaxHealth, humanoid.Health = 100000, 100000
		row.token = token
		if case.model then
			local vehicle = VehicleService.Create(arena, c + Vector3.new(0, 3, 0), 0, "car", { model = case.model })
			assert(vehicle, "no vehicle " .. case.model)
			row.vehicle = vehicle
			task.wait(1)
			local seat = vehicle:FindFirstChild(case.seat)
			assert(seat, case.model .. " has no " .. case.seat)
			row.seated = sit(humanoid, root, seat)
		else
			root.Anchored = true
		end
		-- The bot off the vehicle's side (+X), or ahead of it (-Z is the front), facing the rider.
		local off = case.front and Vector3.new(0, 0, -case.range) or Vector3.new(case.range, 0, 0)
		local at = c + off + Vector3.new(0, 3.2, 0)
		if case.wall then
			block("Wall", Vector3.new(2, 16, 20), CFrame.new(c + off * 0.5 + Vector3.new(0, 8, 0)))
		end
		local bot = BotService.Spawn(1, function()
			return CFrame.lookAt(at, Vector3.new(c.X, at.Y, c.Z))
		end, function() end)[1]
		assert(bot, "no bot")
		bot.weapon = WeaponData.Get("CrocodiloRifle")
		bot.character.HumanoidRootPart.Anchored = true
		if not case.seek then
			bot.noVehicleUntil = math.huge
		end
		row.bot = bot
		shooters[bot] = row
		rows[index] = row
		if index == 1 then
			-- The camera on the thing under test: the first bot and its car.
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame = CFrame.lookAt(c + Vector3.new(case.range * 0.5, 25, 45), c + Vector3.new(case.range * 0.5, 2, 0))
			end
		end
	end)
	if not ok then
		say("case %s SETUP FAILED: %s", case.name, tostring(err))
	end
end

BotService.Start()
local start = tick()
while tick() - start < ROUND_SECONDS do
	task.wait(0.1)
	for _, row in pairs(rows) do
		row.samples += 1
		if row.bot.target == row.token then
			row.targeted += 1
		end
		if row.bot.boarding then
			row.boarding += 1
			row.boardSeat = row.bot.boarding.seat.Name
		end
	end
end

for index, case in ipairs(CASES) do
	local row = rows[index]
	if row then
		local humanoid = row.token.character:FindFirstChildOfClass("Humanoid")
		local seatNow = humanoid and humanoid.SeatPart and humanoid.SeatPart.Name or "none"
		local _, coverSeat = VehicleCover.SeatOf(row.token.character)
		say("%s: seated %s (SeatPart %s, VehicleCover seat %s); targeted %d/%d samples (%.0f%%), shots %d, hits on the rider %d (%.1f dmg), vehicle took %.1f; boarding %d samples%s",
			case.name, tostring(row.seated), seatNow, coverSeat and coverSeat.Name or "none",
			row.targeted, row.samples, 100 * row.targeted / math.max(1, row.samples), row.shots,
			row.riderHits, row.riderDamage, row.vehicleDamage, row.boarding,
			row.boardSeat and (" (walking to its " .. row.boardSeat .. ")") or "")
	end
end
say("done")
BotService.Clear()
