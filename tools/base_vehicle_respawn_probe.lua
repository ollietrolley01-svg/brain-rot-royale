-- Base vehicle respawn probe (Oliver 09-25: "make the vehicles at the bases respawn when destroyed").
-- REAL physics (Run mode, proved below), the real map, the real ModeTeams.Setup for a Team Deathmatch,
-- the real respawn loop. Destroys the base vehicles every way the game allows and logs what the loop sees.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/base_vehicle_respawn_probe.lua -WaitSeconds 600 -PlaceFile <your build>
-- then feed the output to tools/base_vehicle_respawn_check.py --probe-log <file>.
--
-- RespawnDelay and AbandonSeconds are shortened (the rule is the same, the wait is not) so it fits a run.
-- Team 1: health to 0 by a gun, a blast, the chassis broken, every part deleted, fallen off the map,
-- drowned. Team 2: driven far and abandoned, wrecked in a bay full of rubble, wrecked in a bay with a
-- wall put in it for good, wrecked with a player standing in its bay, two left alone (never replaced).
-- Then a restart (Setup again, as a new match or a team-picker restart does) must leave exactly one loop
-- ticking, and a wreck after it must still be replaced. Then Teardown must stop the loop.
--
-- Lines start "[BVR]".

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TAG = "[BVR]"
local function out(format, ...)
	print(TAG .. " " .. string.format(format, ...))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(2)
do
	local ball = Instance.new("Part")
	ball.Size = Vector3.new(2, 2, 2)
	ball.Position = Vector3.new(9000, 900, 9000)
	ball.Parent = workspace
	local y0 = ball.Position.Y
	task.wait(1)
	out("PHYSICS running=%s fell=%.2f", tostring(RunService:IsRunning()), y0 - ball.Position.Y)
	ball:Destroy()
end

local modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(modules:WaitForChild("VehicleService"))
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ModeTeams = require(modules:WaitForChild("ModeTeams"))
local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))
local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

VehicleService.Start()
local cfg = MatchConfig.TeamBaseVehicles
cfg.RespawnDelay = 6
cfg.AbandonSeconds = 6
out("CONFIG delay=%s abandonSeconds=%s abandonDistance=%s", tostring(cfg.RespawnDelay), tostring(cfg.AbandonSeconds), tostring(cfg.AbandonDistance))

-- Every tick the loop runs, and every error it dies of.
local ticks, tickErrors = 0, 0
local originalTick = ModeTeams.TickBaseVehicles
ModeTeams.TickBaseVehicles = function(nowMs)
	ticks += 1
	local ok, problem = pcall(originalTick, nowMs)
	if not ok then
		tickErrors += 1
		out("TICKERROR %s", tostring(problem))
		error(problem)
	end
end

local ok, info = pcall(MapGenerator.Build, "RotRidge")
if not ok then
	out("MAPFAIL %s", tostring(info))
	return
end
local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
local centre = ModeTeams.Setup(mode, info)
out("SETUP ruins=%s/%s", tostring(ModeTeams.BaseRuin(1) ~= nil), tostring(ModeTeams.BaseRuin(2) ~= nil))
task.wait(3)

local function homeOf(team)
	return ModeTeams.BasePads(team)[1]
end
local function flat(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end
local function teamOf(model)
	local p = model:GetPivot().Position
	return flat(p, homeOf(1)) < flat(p, homeOf(2)) and 1 or 2
end
local function whole(model)
	if not model.Parent or model:GetAttribute("Wrecked") == true then
		return false
	end
	local chassis = model.PrimaryPart
	if not chassis or not chassis.Parent then
		return false
	end
	local p = chassis.Position
	return p.Y > workspace.FallenPartsDestroyHeight + 50
end

local folder = ModeTeams.BaseVehicleFolder()
local creates = { 0, 0 }
local created = {}
folder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		task.defer(function()
			if child.Parent then
				local team = teamOf(child)
				creates[team] += 1
				created[child] = team
			end
		end)
	end
end)

local byTeam = { {}, {} }
for _, child in ipairs(folder:GetChildren()) do
	if child:IsA("Model") then
		table.insert(byTeam[teamOf(child)], child)
	end
end
out("PARKED team1=%d team2=%d", #byTeam[1], #byTeam[2])

local function status(label)
	local counts = {}
	for team = 1, 2 do
		local n = 0
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("Model") and whole(child) and teamOf(child) == team and flat(child:GetPivot().Position, homeOf(team)) < 150 then
				n += 1
			end
		end
		counts[team] = n
	end
	out("STATUS %s live1=%d live2=%d home1=%d home2=%d creates1=%d creates2=%d ticks=%d tickErrors=%d", label,
		ModeTeams.LiveBaseVehicles(1), ModeTeams.LiveBaseVehicles(2), counts[1], counts[2], creates[1], creates[2], ticks, tickErrors)
	return counts
end
status("start")

local scratch = Instance.new("Folder")
scratch.Name = "BVRProbe"
scratch.Parent = workspace

local function groundAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0))
	return hit and hit.Position.Y or 0
end

local t1, t2 = byTeam[1], byTeam[2]
local blocks = {}
local dummy

-- Team 1 -----------------------------------------------------------------------------------------
if t1[1] then
	VehicleService.DamageVehicle(nil, t1[1], 1e6, "bullet")
	out("DO gun %s wrecked=%s", t1[1].Name, tostring(t1[1]:GetAttribute("Wrecked")))
end
if t1[2] then
	-- A direct hit, small enough that the next bay's car is not caught in it (the first run's 20-stud
	-- blast wrecked three).
	VehicleService.BlastDamage({ position = t1[2].PrimaryPart.Position, radius = 3, innerRadius = 1, damage = 1e5,
		directVehicle = t1[2], directBonus = 1e5 })
	out("DO blast %s wrecked=%s", t1[2].Name, tostring(t1[2]:GetAttribute("Wrecked")))
end
if t1[3] then
	t1[3].PrimaryPart:Destroy()
	out("DO chassis-broken %s wrecked=%s parent=%s", t1[3].Name, tostring(t1[3]:GetAttribute("Wrecked")), tostring(t1[3].Parent ~= nil))
end
if t1[4] then
	for _, part in ipairs(t1[4]:GetDescendants()) do
		if part:IsA("BasePart") then
			part:Destroy()
		end
	end
	out("DO emptied %s wrecked=%s parent=%s", t1[4].Name, tostring(t1[4]:GetAttribute("Wrecked")), tostring(t1[4].Parent ~= nil))
end
local fallen = t1[5]
if fallen then
	VehicleService.Wake(fallen)
	for _, part in ipairs(fallen:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
		end
	end
	local p = fallen:GetPivot().Position
	fallen:PivotTo(CFrame.new(p.X, workspace.FallenPartsDestroyHeight + 30, p.Z))
	out("DO fall %s", fallen.Name)
end
local drowned = t1[6]
if drowned then
	local home = homeOf(1)
	local floorY = groundAt(home.X, home.Z) + 120
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(44, 2, 44)
	floor.CFrame = CFrame.new(home.X, floorY, home.Z)
	floor.Parent = scratch
	workspace.Terrain:FillBlock(CFrame.new(home.X, floorY + 10, home.Z), Vector3.new(40, 18, 40), Enum.Material.Water)
	VehicleService.Wake(drowned)
	drowned:PivotTo(CFrame.new(home.X, floorY + 4, home.Z))
	out("DO drown %s", drowned.Name)
end

-- Team 2 -----------------------------------------------------------------------------------------
if t2[1] then
	local x, z = centre.X, centre.Z
	VehicleService.Wake(t2[1])
	t2[1]:PivotTo(CFrame.new(x, groundAt(x, z) + 4, z))
	out("DO abandon %s at %.0f studs", t2[1].Name, flat(t2[1]:GetPivot().Position, homeOf(2)))
end
local function block(model, rubble)
	local p = model:GetPivot().Position
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = rubble and Vector3.new(5, 3, 5) or Vector3.new(9, 7, 16)
	part.CFrame = CFrame.new(p.X, p.Y + (rubble and 3.5 or 5), p.Z)
	part.Name = rubble and "RubbleChunk" or "PermanentWall"
	if rubble then
		part:SetAttribute("Rubble", true)
	end
	part.CanCollide = true
	part.Parent = scratch
	table.insert(blocks, { part = part, rubble = rubble, at = p })
	VehicleService.DamageVehicle(nil, model, 1e6, "bullet")
	return part
end
if t2[2] then
	block(t2[2], true)
	out("DO rubble-bay %s", t2[2].Name)
end
if t2[3] then
	block(t2[3], false)
	out("DO walled-bay %s", t2[3].Name)
end
if t2[4] then
	local p = t2[4]:GetPivot().Position
	VehicleService.DamageVehicle(nil, t2[4], 1e6, "bullet")
	dummy = Instance.new("Model")
	dummy.Name = "BVRDummy"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CFrame = CFrame.new(p.X, p.Y + 3, p.Z)
	root.Parent = dummy
	Instance.new("Humanoid").Parent = dummy
	dummy.PrimaryPart = root
	dummy.Parent = scratch
	out("DO person-in-bay %s", t2[4].Name)
end

for second = 1, 45 do
	task.wait(1)
	if second == 2 and fallen then
		local left = 0
		for _, part in ipairs(fallen:GetDescendants()) do
			if part:IsA("BasePart") then
				left += 1
			end
		end
		out("FELL %s parent=%s parts=%d wrecked=%s", fallen.Name, tostring(fallen.Parent ~= nil), left, tostring(fallen:GetAttribute("Wrecked")))
	end
	if second % 3 == 0 then
		status("t" .. second)
	end
end

local final = status("final")
for _, entry in ipairs(blocks) do
	out("BLOCK %s standing=%s", entry.part.Name, tostring(entry.part.Parent ~= nil))
end
local inside = 0
for child in pairs(created) do
	if child.Parent then
		local p = child:GetPivot().Position
		if dummy and flat(p, dummy.PrimaryPart.Position) < 5 then
			inside += 1
		end
		for _, entry in ipairs(blocks) do
			if not entry.rubble and entry.part.Parent and flat(p, entry.at) < 5 then
				inside += 1
			end
		end
	end
end
out("OVERLAP inPlayerOrWall=%d", inside)
-- Where team 2's bays are against the blocks, and what stands in each.
for index, bay in ipairs(ModeTeams.RuinBays(2)) do
	local near = "-"
	for _, entry in ipairs(blocks) do
		if flat(bay.Position, entry.at) < 3 then
			near = entry.part.Name
		end
	end
	local car = "empty"
	for _, child in ipairs(folder:GetChildren()) do
		if child:IsA("Model") and flat(child:GetPivot().Position, bay.Position) < 3 then
			car = created[child] and "replacement" or "original"
		end
	end
	out("BAY2 %d block=%s car=%s", index, near, car)
end
for index, slot in ipairs(ModeTeams.BaseVehicleSlots and ModeTeams.BaseVehicleSlots(2) or {}) do
	local p = slot.model and slot.model.Parent and slot.model:GetPivot().Position
	out("SLOT2 %d inBay=%s bayFails=%s", index, tostring(p ~= nil and (function()
		for _, bay in ipairs(ModeTeams.RuinBays(2)) do
			if flat(bay.Position, p) < 3 then
				return true
			end
		end
		return false
	end)()), tostring(slot.bayFails))
end
local lost1 = math.min(#t1, 6)
local lost2 = math.min(#t2, 4)
out("RESULT home1=%d/%d home2=%d/%d creates1=%d want %d creates2=%d want %d tickErrors=%d", final[1], #t1, final[2], #t2,
	creates[1], lost1, creates[2], lost2, tickErrors)

-- Restart: exactly one loop afterwards, and it still replaces a wreck.
ModeTeams.Setup(mode, info)
task.wait(3)
folder = ModeTeams.BaseVehicleFolder()
local before = ticks
task.wait(6)
out("RESTART ticksIn6s=%d", ticks - before)
local victim
for _, child in ipairs(folder:GetChildren()) do
	if child:IsA("Model") and whole(child) then
		victim = child
		break
	end
end
local liveTeam = victim and teamOf(victim) or 1
local liveBefore = ModeTeams.LiveBaseVehicles(liveTeam)
if victim then
	VehicleService.DamageVehicle(nil, victim, 1e6, "bullet")
end
task.wait(cfg.RespawnDelay + 4)
out("RESTART replaced=%s live=%d want %d", tostring(ModeTeams.LiveBaseVehicles(liveTeam) == liveBefore), ModeTeams.LiveBaseVehicles(liveTeam), liveBefore)
ModeTeams.Teardown()
before = ticks
task.wait(3)
out("TEARDOWN ticksIn3s=%d", ticks - before)
scratch:Destroy()
out("DONE")
