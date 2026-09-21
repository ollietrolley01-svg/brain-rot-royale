-- Probe for tools/runtest.ps1 -Probe: a vehicle's driver can't shoot, whatever the client sends.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/driver_fire_probe.lua
--
-- Sits a stand-in character (root, head, humanoid) on nothing, on a VehicleSeat (the driver's seat
-- VehicleService builds) and on a plain Seat (a passenger's), and calls the real CombatService.Fire
-- for each. Fire's next check after the driving refusal is Combatants.IsAlive, so that's wrapped to
-- count calls: a refused shot never reaches it. Expected: standing and passenger reach it, the
-- driver doesn't. Everything the probe makes is destroyed and the wrap undone at the end.

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local CombatService = require(modules:WaitForChild("CombatService"))
local Combatants = require(modules:WaitForChild("Combatants"))

local function out(fmt, ...)
	print("[AUDIT driver] " .. string.format(fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "DriverFireProbe"
folder.Parent = workspace
local BASE = Vector3.new(0, 5000, 0)

local function part(className, name, size, position, parent)
	local p = Instance.new(className)
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.CFrame = CFrame.new(position)
	p.Parent = parent
	return p
end

local function rig(offset)
	local model = Instance.new("Model")
	model.Name = "StandIn"
	local root = part("Part", "HumanoidRootPart", Vector3.new(2, 2, 1), BASE + offset + Vector3.new(0, 3, 0), model)
	root.Anchored = false
	part("Part", "Head", Vector3.new(2, 1, 1), BASE + offset + Vector3.new(0, 4.5, 0), model).Anchored = false
	local neck = Instance.new("WeldConstraint")
	neck.Part0 = root
	neck.Part1 = model.Head
	neck.Parent = root
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = folder
	return model, humanoid, root
end

-- Seats the humanoid: Seat:Sit first; if the engine doesn't set SeatPart in edit mode, a SeatWeld the
-- way the engine makes one.
local function seat(humanoid, root, seatPart)
	pcall(function()
		seatPart:Sit(humanoid)
	end)
	for _ = 1, 10 do
		if humanoid.SeatPart then
			return "Sit"
		end
		task.wait()
	end
	local weld = Instance.new("Weld")
	weld.Name = "SeatWeld"
	weld.Part0 = seatPart
	weld.Part1 = root
	weld.C0 = CFrame.new(0, 0.5 + root.Size.Y / 2, 0)
	weld.Parent = seatPart
	for _ = 1, 10 do
		if humanoid.SeatPart then
			return "SeatWeld"
		end
		task.wait()
	end
	return nil
end

local reached = 0
local current = nil
local realIsAlive = Combatants.IsAlive
Combatants.IsAlive = function(token, ...)
	if token == current then
		reached += 1
		return false -- stop Fire here: nothing below needs to run
	end
	return realIsAlive(token, ...)
end
local wasEnabled = CombatService.IsEnabled()
CombatService.SetEnabled(true)

local cases = {
	{ name = "standing", seatClass = nil, want = 1 },
	{ name = "driver (VehicleSeat)", seatClass = "VehicleSeat", want = 0 },
	{ name = "passenger (Seat)", seatClass = "Seat", want = 1 },
}
local failures = 0
for index, case in ipairs(cases) do
	local offset = Vector3.new(index * 12, 0, 0)
	local model, humanoid, root = rig(offset)
	local how = "-"
	if case.seatClass then
		local seatPart = part(case.seatClass, "ProbeSeat", Vector3.new(2, 1, 2), BASE + offset + Vector3.new(0, 0.5, 0), folder)
		how = seat(humanoid, root, seatPart) or "NOT SEATED"
	end
	local standIn = { Character = model, Name = "StandIn" .. index, UserId = -index }
	current = standIn
	reached = 0
	local driving = CombatService.IsDriving(standIn)
	local ok, err = pcall(CombatService.Fire, standIn, BASE + offset + Vector3.new(0, 4.5, -60))
	current = nil
	local seatText = humanoid.SeatPart and humanoid.SeatPart.ClassName or "none"
	local pass = ok and reached == case.want and how ~= "NOT SEATED"
	if not pass then
		failures += 1
	end
	out("%s: seated by %s, SeatPart %s, IsDriving %s, Fire %s, reached the alive check %d time(s) (want %d) -> %s",
		case.name, how, seatText, tostring(driving), ok and "ran" or ("errored: " .. tostring(err)), reached, case.want,
		pass and "PASS" or "FAIL")
end

-- A player that isn't a Player or a table (a bot's Model token) is never "driving" and never errors.
local okModel, drivingModel = pcall(CombatService.IsDriving, Instance.new("Model"))
out("non-player token: IsDriving %s", okModel and tostring(drivingModel) or "errored")
if not okModel or drivingModel then
	failures += 1
end

Combatants.IsAlive = realIsAlive
CombatService.SetEnabled(wasEnabled)
folder:Destroy()
out("RESULT %s (%d failure(s))", failures == 0 and "PASS" or "FAIL", failures)
pcall(flush)
