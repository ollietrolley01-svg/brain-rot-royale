-- Can a player get out of the river, and at what bank angle? The river measurements say the gentlest
-- entry anywhere on any map is 23 degrees over the 4 studs at the waterline, so today the answer is
-- "by falling in and swimming to a bridge". Before designing banks with real entries, this measures
-- what a character can actually climb out of water onto, and how fast it swims -- because the entry
-- SPACING is only defensible against a measured swim speed.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/road_bank_probe.lua -WaitSeconds 900 [-PlaceFile <rbxlx>]
--
-- Edit-mode probes have no physics, so this switches the snapshot into Run mode itself (the same
-- thing tools/movement_probe.lua does) and drives a stock R15 rig, which is the controller a player's
-- character runs.
--
-- Lanes are built far from any map, one per bank angle, each a channel of water with a bank rising out
-- of it at that angle. Two lanes prove the measurement rather than add to it: a flat lane, where the
-- rig must measure the walk speed the config sets (18), and a vertical wall, which it must NOT escape.
-- If the wall lane reports an escape, nothing else here is worth reading.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local ORIGIN = Vector3.new(6000, 0, -6000) -- far from anything the map builds
local LANE_GAP = 120
local CELL = 4
local BED = -7 -- the river's bed today
local WATER_TOP = -1 -- and its surface
local LAND = 6 -- the flat top of each bank
local CHANNEL = 56 -- studs of water in front of the bank
local ANGLES = { 12, 16, 20, 25, 30, 35, 40, 45, 50, 60, 70 }

local function out(fmt, ...)
	print("[BANK] " .. string.format(fmt, ...))
end

local terrain = workspace.Terrain
local lift = 2 -- MapTerrain.SurfaceLift; read below from the module so the two cannot drift
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local okTerrain, MapTerrain = pcall(require, modules:WaitForChild("MapTerrain"))
if okTerrain and MapTerrain and MapTerrain.SurfaceLift then
	lift = MapTerrain.SurfaceLift
end

-- One lane of terrain: bed and water from x = -CHANNEL to 0, then ground rising at `angle` up to LAND,
-- then flat. Written with WriteVoxels and fractional occupancy, which places the surface exactly --
-- FillBlock would quantise every slope to 4-stud steps and this probe would be measuring stairs.
local function buildLane(centre, angle)
	local rise = LAND - BED
	local run = rise / math.tan(math.rad(angle))
	local minX, maxX = centre.X - CHANNEL - 24, centre.X + run + 60
	local minZ, maxZ = centre.Z - 40, centre.Z + 40
	local region = Region3.new(Vector3.new(minX, BED - 16, minZ), Vector3.new(maxX, LAND + 12, maxZ)):ExpandToGrid(CELL)
	local size = region.Size / CELL
	local origin = region.CFrame.Position - region.Size / 2
	local materials, occupancies = {}, {}
	for ix = 1, size.X do
		local x = origin.X + (ix - 0.5) * CELL
		local along = x - centre.X
		local height
		if along <= 0 then
			height = BED
		elseif along >= run then
			height = LAND
		else
			height = BED + along * math.tan(math.rad(angle))
		end
		materials[ix], occupancies[ix] = {}, {}
		for iy = 1, size.Y do
			local bottom = origin.Y + (iy - 1) * CELL
			materials[ix][iy], occupancies[ix][iy] = {}, {}
			local occupancy = math.clamp((height - lift - bottom) / CELL, 0, 1)
			for iz = 1, size.Z do
				materials[ix][iy][iz] = occupancy > 0 and Enum.Material.Grass or Enum.Material.Air
				occupancies[ix][iy][iz] = occupancy
			end
		end
	end
	terrain:WriteVoxels(region, CELL, materials, occupancies)
	-- Water over the bed, up to the waterline. The ground above the bed is already air here, so this
	-- does not need the air carve a lake does.
	local waterEdge = centre.X + (WATER_TOP - BED) / math.tan(math.rad(angle))
	local length = waterEdge - (centre.X - CHANNEL)
	terrain:FillBlock(CFrame.new(centre.X - CHANNEL + length / 2, (BED + WATER_TOP) / 2, centre.Z),
		Vector3.new(length, WATER_TOP - BED, 72), Enum.Material.Water)
	return waterEdge
end

local template = nil
local function makeRig()
	if not template then
		for attempt = 1, 3 do
			local ok, model = pcall(function()
				return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
			end)
			if ok and model then
				template = model
				break
			end
			out("rig attempt %d failed: %s", attempt, tostring(model))
			task.wait(2)
		end
	end
	if not template then
		return nil
	end
	local rig = template:Clone()
	rig.Parent = workspace
	return rig
end

-- Drives `step` every Heartbeat until it returns true or `timeout` seconds pass. Wall clock, because
-- os.clock is CPU time in Roblox and a frame that yields understates itself.
local function drive(timeout, step)
	local started = DateTime.now().UnixTimestampMillis
	local finished = false
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if finished then
			return
		end
		local elapsed = (DateTime.now().UnixTimestampMillis - started) / 1000
		local ok, result = pcall(step, dt, elapsed)
		if not ok then
			out("step error: %s", tostring(result))
			finished = true
		elseif result or elapsed > timeout then
			finished = true
		end
	end)
	while not finished do
		task.wait()
	end
	connection:Disconnect()
	return (DateTime.now().UnixTimestampMillis - started) / 1000
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(4)
out("gravity %.1f, maxSlopeAngle %.1f, jumpHeight %.2f, useJumpPower %s -- the settings a player gets",
	workspace.Gravity, StarterPlayer.CharacterMaxSlopeAngle, StarterPlayer.CharacterJumpHeight,
	tostring(StarterPlayer.CharacterUseJumpPower))

-- The control lane: flat ground, no water. The rig must measure the walk speed MatchConfig sets. A
-- probe that cannot reproduce a known number has not earned the ones nobody knows.
do
	local centre = ORIGIN
	terrain:FillBlock(CFrame.new(centre.X, LAND - 2 - lift, centre.Z), Vector3.new(400, 4, 72), Enum.Material.Grass)
	task.wait(0.5)
	local rig = makeRig()
	if not rig then
		out("no rig available: nothing below can be measured")
		return
	end
	local humanoid = rig:WaitForChild("Humanoid")
	rig:PivotTo(CFrame.new(centre.X - 120, LAND + 4, centre.Z))
	task.wait(1)
	local from = rig.PrimaryPart.Position
	local moved = 0
	drive(3, function()
		humanoid:Move(Vector3.new(1, 0, 0))
		moved = (rig.PrimaryPart.Position - from).Magnitude
		return false
	end)
	out("control, flat ground: walked %.1f studs in 3.0 s = %.1f studs/s (MatchConfig.BaseWalkSpeed is 18, humanoid says %.1f)",
		moved, moved / 3, humanoid.WalkSpeed)
	rig:Destroy()
end

-- Swim speed, in a channel with no way out: this is the number entry spacing has to answer to.
local swimSpeed = nil
do
	local centre = ORIGIN + Vector3.new(0, 0, LANE_GAP)
	local region = Region3.new(Vector3.new(centre.X - 260, BED - 12, centre.Z - 40),
		Vector3.new(centre.X + 40, LAND + 12, centre.Z + 40)):ExpandToGrid(CELL)
	local size = region.Size / CELL
	local origin = region.CFrame.Position - region.Size / 2
	local materials, occupancies = {}, {}
	for ix = 1, size.X do
		materials[ix], occupancies[ix] = {}, {}
		for iy = 1, size.Y do
			local bottom = origin.Y + (iy - 1) * CELL
			materials[ix][iy], occupancies[ix][iy] = {}, {}
			local occupancy = math.clamp((BED - lift - bottom) / CELL, 0, 1)
			for iz = 1, size.Z do
				materials[ix][iy][iz] = occupancy > 0 and Enum.Material.Grass or Enum.Material.Air
				occupancies[ix][iy][iz] = occupancy
			end
		end
	end
	terrain:WriteVoxels(region, CELL, materials, occupancies)
	terrain:FillBlock(CFrame.new(centre.X - 110, (BED + WATER_TOP) / 2, centre.Z),
		Vector3.new(290, WATER_TOP - BED, 72), Enum.Material.Water)
	task.wait(0.5)
	local rig = makeRig()
	local humanoid = rig:WaitForChild("Humanoid")
	rig:PivotTo(CFrame.new(centre.X - 220, WATER_TOP - 1, centre.Z))
	task.wait(1.5)
	local state = humanoid:GetState()
	local from = rig.PrimaryPart.Position
	local moved = 0
	drive(4, function()
		humanoid:Move(Vector3.new(1, 0, 0))
		moved = (rig.PrimaryPart.Position - from).Magnitude
		return false
	end)
	swimSpeed = moved / 4
	out("swim: %.1f studs in 4.0 s = %.1f studs/s, humanoid state %s (walking is %.1f)",
		moved, swimSpeed, tostring(state), humanoid.WalkSpeed)
	rig:Destroy()
end

-- The banks. One lane per angle, plus a vertical wall as the planted fault.
local escaped, stuck = {}, {}
local lanes = {}
for _, angle in ipairs(ANGLES) do
	table.insert(lanes, angle)
end
table.insert(lanes, 90) -- the wall: must fail
for index, angle in ipairs(lanes) do
	local centre = ORIGIN + Vector3.new(0, 0, (index + 1) * LANE_GAP)
	local waterEdge = buildLane(centre, angle)
	task.wait(0.4)
	local rig = makeRig()
	if not rig then
		out("lane %d deg: no rig", angle)
		break
	end
	local humanoid = rig:WaitForChild("Humanoid")
	-- In the water, a third of the way across, facing the bank.
	rig:PivotTo(CFrame.new(centre.X - CHANNEL / 2, WATER_TOP - 1, centre.Z))
	task.wait(1.5)
	local best, bestAt = -math.huge, 0
	local out_ = false
	local took = drive(12, function(_, elapsed)
		humanoid:Move(Vector3.new(1, 0, 0))
		local y = rig.PrimaryPart.Position.Y
		if y > best then
			best, bestAt = y, elapsed
		end
		-- Out means standing on land above the waterline, not merely bobbing at it.
		if y > WATER_TOP + 3 and humanoid.FloorMaterial ~= Enum.Material.Air and humanoid.FloorMaterial ~= Enum.Material.Water then
			out_ = true
			return true
		end
		return false
	end)
	local x = rig.PrimaryPart.Position.X
	out("bank %2d deg (waterline at x+%.0f, %.0f studs of bank to the top): %s -- highest y %.2f after %.1f s, ended %.0f studs %s the waterline, floor %s",
		angle, waterEdge - centre.X, (LAND - WATER_TOP) / math.tan(math.rad(angle)),
		out_ and string.format("OUT in %.1f s", took) or "STILL IN THE WATER after 12 s",
		best, bestAt, math.abs(x - waterEdge), x > waterEdge and "past" or "short of", tostring(humanoid.FloorMaterial))
	if out_ then
		table.insert(escaped, angle)
	else
		table.insert(stuck, angle)
	end
	rig:Destroy()
	task.wait(0.2)
end

local gentlest = nil
for _, angle in ipairs(escaped) do
	if angle == 90 then
		out("PLANTED FAULT DID NOT FIRE: the rig climbed a vertical wall, so every line above is suspect")
	elseif not gentlest or angle > gentlest then
		gentlest = angle
	end
end
local steepestOut = gentlest
local walls = {}
for _, angle in ipairs(stuck) do
	table.insert(walls, tostring(angle))
end
out("climbed out of the water at: %s", #escaped > 0 and table.concat((function()
	local list = {}
	for _, angle in ipairs(escaped) do
		table.insert(list, tostring(angle))
	end
	return list
end)(), ", ") .. " deg" or "no angle at all")
out("could not: %s deg", table.concat(walls, ", "))
if steepestOut and swimSpeed then
	out("so an entry has to be no steeper than %d deg, and at %.1f studs/s of swimming, entries every E studs cost a player at worst E/2 / %.1f = %.2f s of swimming per 100 studs of spacing",
		steepestOut, swimSpeed, swimSpeed, 50 / swimSpeed)
end
out("done")
