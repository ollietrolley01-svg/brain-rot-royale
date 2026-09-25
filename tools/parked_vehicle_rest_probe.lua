-- Parked vehicle rest probe (Oliver 09-24: "the cars bounce around and are unstable until someone starts
-- driving them"). Measured with REAL physics: Run mode, the way tools/mapvehicle_physics_probe.lua does.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/parked_vehicle_rest_probe.lua -WaitSeconds 600 -PlaceFile <your build>
-- then feed the output to tools/parked_vehicle_rest_check.py.
--
-- Every vehicle is made by VehicleService.Create and stepped by VehicleService's own loop, with nobody
-- anywhere near. Rows, all at once, far from the lobby and any map:
--   flat     asphalt slab
--   slopeL   a 7 degree slab, the car nose-down it
--   slopeX   a 5 degree slab, the car across it
--   bay      the way a town car park is laid: a collidable grass base, a non-colliding road slab 0.4
--            proud (MapDecor.RoadLift) and bay paint over it
--   yard     a bay, with the chassis anchored at spawn and let go 1.5 s later: ModeTeams' base-yard path
-- plus every vehicle the real SahurSprings map parks (MapGenerator.Build).
-- Per vehicle, from 6 s after spawn for 60 s: largest drift from the pose at 6 s (studs, degrees), largest
-- linear and angular speed, vertical bounces (sign changes of vertical speed past 0.15 studs/s), and who
-- owns its physics (server, manually, is the only right answer for an empty vehicle).
-- Then the wake rows: a bot sits and drives off (the jolt at the moment it sits, distance in 2 s); a
-- blast (ApplyBlast) and a ramming car must each move a resting car.
-- Ownership: Run mode has no clients, and there GetNetworkOwnershipAuto reads true even straight after a
-- successful SetNetworkOwner(nil) (the OWNERAPI line shows it), so the row reports whether VehicleService's
-- own call to pin the physics to the server succeeded ("pinned"), which is what a live server obeys.
-- Planted faults, always run: "FAULT_nohold" (the rest hold switched off: the old one-step-in-eight rest)
-- and "FAULT_owner" (the base-yard start, anchored so the first ownership call fails, with the retry and
-- the guard switched off). Each must FAIL.
--
-- Lines start "[REST]": "[REST] PHYSICS", "[REST] row <name> key=value ...", "[REST] wake <name> ...".

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(modules:WaitForChild("VehicleService"))

local TAG = "[REST]"
local function out(format, ...)
	print(TAG .. " " .. string.format(format, ...))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(2)

-- Prove physics steps before believing any number.
do
	local ball = Instance.new("Part")
	ball.Size = Vector3.new(2, 2, 2)
	ball.Position = Vector3.new(6000, 900, 6000)
	ball.Parent = workspace
	local y0 = ball.Position.Y
	task.wait(1)
	out("PHYSICS running=%s fell=%.2f", tostring(RunService:IsRunning()), y0 - ball.Position.Y)
	ball:Destroy()
end

-- Can this context hand a part's physics to the server at all? (Logged: in Run mode the engine reports automatic ownership regardless.)
do
	local p = Instance.new("Part")
	p.Position = Vector3.new(6000, 950, 6100)
	p.Parent = workspace
	local ok, err = pcall(function()
		p:SetNetworkOwner(nil)
	end)
	local okA, auto = pcall(function()
		return p:GetNetworkOwnershipAuto()
	end)
	out("OWNERAPI set=%s err=%s auto=%s", tostring(ok), tostring(err), tostring(okA and auto))
	p:Destroy()
end

VehicleService.Start()

local CX, CZ = 6000, 6000
local folder = Instance.new("Folder")
folder.Name = "ParkedRestProbe"
folder.Parent = workspace

local function slab(size, cf, collide, material, color)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = collide
	part.Size = size
	part.CFrame = cf
	part.Material = material or Enum.Material.Asphalt
	part.Color = color or Color3.fromRGB(60, 60, 64)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = folder
	return part
end

local MODELS = { "Rotster", "SahurVan", "TralalaGT", "CrocodiloRanger", "PatapimScrambler", "BananiniScoot", "BrrStreetfighter" }
local VehicleModels = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("VehicleModels"))

local tracked = {}
local faultsPlanted = false

local function track(name, model, planted)
	table.insert(tracked, { name = name, model = model, planted = planted, born = tick(),
		maxDrift = 0, maxAngle = 0, maxV = 0, maxW = 0, bounces = 0, lastVy = 0 })
end

-- One lane per ground type, one vehicle per model along it. Ground top at y = 0 at the car.
local lanes = {
	{ name = "flat", tilt = CFrame.new() },
	{ name = "slopeL", tilt = CFrame.Angles(math.rad(7), 0, 0) },
	{ name = "slopeX", tilt = CFrame.Angles(0, 0, math.rad(5)) },
	{ name = "bay" },
	{ name = "yard" },
	{ name = "FAULT_nohold", tilt = CFrame.new() },
	{ name = "FAULT_owner" },
}

for laneIndex, lane in ipairs(lanes) do
	local x = CX + laneIndex * 70
	local length = #MODELS * 30 + 20
	local centre = CFrame.new(x, 0, CZ)
	if lane.tilt then
		slab(Vector3.new(40, 4, length), centre * lane.tilt * CFrame.new(0, -2, 0), true)
	else
		slab(Vector3.new(40, 4, length), centre * CFrame.new(0, -2, 0), true, Enum.Material.Grass, Color3.fromRGB(80, 140, 60))
		slab(Vector3.new(34, 0.4, length - 4), centre * CFrame.new(0, 0.2, 0), false)
		for i = 1, #MODELS do
			slab(Vector3.new(0.3, 0.05, 16), centre * CFrame.new(-6, 0.43, (i - (#MODELS + 1) / 2) * 30 - 15), false,
				Enum.Material.SmoothPlastic, Color3.new(1, 1, 1))
		end
	end
	for i, modelId in ipairs(MODELS) do
		local def = VehicleModels.Models[modelId]
		if def then
			local z = CZ + (i - (#MODELS + 1) / 2) * 30
			local ground = (centre * (lane.tilt or CFrame.new())):PointToWorldSpace(Vector3.new(0, 0, z - CZ))
			local y = lane.tilt and ground.Y or 0.4
			local model = VehicleService.Create(folder, Vector3.new(x, y, z), 0, def.kind, { model = modelId, exact = true })
			if model then
				local name = lane.name .. ":" .. modelId
				if lane.name == "FAULT_nohold" then
					VehicleService.Get(model).noRestHold = true
					VehicleService.Wake(model)
					faultsPlanted = true
				end
				if lane.name == "FAULT_owner" then
					-- The base-yard start (anchored, so the first ownership call fails) with the retry and
					-- the guard switched off: the server never takes its physics.
					local entry = VehicleService.Get(model)
					entry.noOwnerRetry = true
					entry.noOwnerGuard = true
				end
				if (lane.name == "yard" or lane.name == "FAULT_owner") and model.PrimaryPart then
					local chassis = model.PrimaryPart
					chassis.Anchored = true
					task.delay(1.5, function()
						chassis.Anchored = false
					end)
				end
				track(name, model, lane.name:sub(1, 6) == "FAULT_" and lane.name or nil)
			else
				out("PROBLEM could not create %s on %s", modelId, lane.name)
			end
		end
	end
end

-- Sample every frame. Reference pose at SETTLE seconds after the row was made, then WINDOW seconds.
local SETTLE, WINDOW = 6, 60
local startAll = tick()
local conn = RunService.Heartbeat:Connect(function()
	for _, t in ipairs(tracked) do
		local chassis = t.model.PrimaryPart
		if (not chassis or not chassis.Parent) and not t.goneAt then
			t.goneAt = tick() - t.born
			t.goneHealth = t.model:GetAttribute("VehicleHealth")
			t.goneParent = t.model.Parent and t.model.Parent:GetFullName() or "nil"
		end
		if chassis and chassis.Parent then
			local age = tick() - t.born
			-- Is VehicleService stepping it at all? (Held vehicles are skipped on purpose.)
			local e = VehicleService.Get(t.model)
			if e and e.rig and e.rig.steppedAt and not e.restHold and age > 1 then
				t.stale = math.max(t.stale or 0, tick() - e.rig.steppedAt)
			end
			if age >= SETTLE and not t.ref then
				t.ref = chassis.CFrame
			end
			if t.ref and age < SETTLE + WINDOW then
				local cf = chassis.CFrame
				t.maxDrift = math.max(t.maxDrift, (cf.Position - t.ref.Position).Magnitude)
				local _, angle = (t.ref:Inverse() * cf):ToAxisAngle()
				t.maxAngle = math.max(t.maxAngle, math.deg(math.abs(angle)))
				local v, w = chassis.AssemblyLinearVelocity, chassis.AssemblyAngularVelocity
				t.maxV = math.max(t.maxV, v.Magnitude)
				t.maxW = math.max(t.maxW, w.Magnitude)
				if math.abs(v.Y) > 0.15 then
					local sign = v.Y > 0 and 1 or -1
					if t.lastVy ~= 0 and sign ~= t.lastVy then
						t.bounces += 1
					end
					t.lastVy = sign
				end
			end
		end
	end
end)
-- The real map's parked vehicles, left to the real map code.
local okMap, mapErr = pcall(function()
	local MapGenerator = require(modules:WaitForChild("MapGenerator"))
	MapGenerator.Build("SahurSprings")
	local map = workspace:FindFirstChild("Map")
	local vehicles = map and map:FindFirstChild("Vehicles")
	for _, model in ipairs(vehicles and vehicles:GetChildren() or {}) do
		if model:IsA("Model") and VehicleService.Get(model) then
			track("map:" .. model.Name, model)
		end
	end
end)
if not okMap then
	out("PROBLEM map build failed: %s", tostring(mapErr))
end

out("tracking %d vehicles (%s)", #tracked, faultsPlanted and "faults planted" or "no-hold fault NOT plantable")

-- Wake rows, on their own lane, started while the rest rows run.
local wakeX = CX + (#lanes + 2) * 70
slab(Vector3.new(60, 4, 600), CFrame.new(wakeX, -2, CZ), true)

local function wakeCar(z, modelId)
	local def = VehicleModels.Models[modelId]
	local model = VehicleService.Create(folder, Vector3.new(wakeX, 0, z), 0, def.kind, { model = modelId, exact = true })
	return model
end

task.spawn(function()
	-- Driver: a bot sits in a car that has been resting 8 s, then throttles.
	local car = wakeCar(CZ - 200, "Rotster")
	task.wait(8)
	local chassis = car.PrimaryPart
	local okRig, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if okRig and rig then
		rig.Parent = folder
		local seat = VehicleService.SeatsOf(car).driver
		rig:PivotTo(seat.CFrame * CFrame.new(3, 2, 0))
		task.wait(0.5)
		local start = chassis.Position
		local sat = VehicleService.BotSit(rig:FindFirstChildOfClass("Humanoid"), seat)
		-- The lurch: the largest speed in the first second after sitting, with no throttle yet.
		local lurch, lurchW = 0, 0
		local t0 = tick()
		while tick() - t0 < 1 do
			lurch = math.max(lurch, chassis.AssemblyLinearVelocity.Magnitude)
			lurchW = math.max(lurchW, chassis.AssemblyAngularVelocity.Magnitude)
			RunService.Heartbeat:Wait()
		end
		local before = chassis.Position
		seat.ThrottleFloat = 1
		task.wait(2)
		seat.ThrottleFloat = 0
		out("wake drive sat=%s lurch=%.3f lurchW=%.3f sitMove=%.3f drove=%.2f", tostring(sat), lurch, lurchW,
			(before - start).Magnitude, (chassis.Position - before).Magnitude)
	else
		out("wake drive sat=false lurch=0 lurchW=0 sitMove=0 drove=0 (no rig)")
	end
end)

task.spawn(function()
	-- Blast: a car resting 8 s, a 100-damage blast 6 studs to its side.
	local car = wakeCar(CZ, "SahurVan")
	task.wait(8)
	local chassis = car.PrimaryPart
	local start = chassis.Position
	VehicleService.ApplyBlast(start + Vector3.new(6, 0, 0), 20, 100)
	task.wait(2)
	out("wake blast moved=%.2f", (chassis.Position - start).Magnitude)
end)

task.spawn(function()
	-- Ram: a car resting 8 s, hit square in the side by a frictionless block at 40 studs/s.
	local car = wakeCar(CZ + 200, "Rotster")
	task.wait(8)
	local chassis = car.PrimaryPart
	local start = chassis.Position
	local block = Instance.new("Part")
	block.Size = Vector3.new(6, 4, 8)
	block.CFrame = CFrame.new(start + Vector3.new(-9, 1.5, 0))
	block.CustomPhysicalProperties = PhysicalProperties.new(4, 0, 0.2, 100, 1)
	block.Parent = folder
	block.AssemblyLinearVelocity = Vector3.new(40, 0, 0)
	task.wait(2)
	out("wake ram moved=%.2f", (chassis.Position - start).Magnitude)
end)

startAll = tick()
while tick() - startAll < SETTLE + WINDOW + 4 do
	task.wait(1)
end
conn:Disconnect()

for _, t in ipairs(tracked) do
	local chassis = t.model.PrimaryPart
	local owner = "gone"
	if chassis and chassis.Parent then
		local okOwner, who = pcall(function()
			return chassis:GetNetworkOwner()
		end)
		owner = (okOwner and who and who.Name) or (okOwner and "server") or "?"
	end
	local entry = VehicleService.Get(t.model)
	out("row %s drift=%.4f angle=%.4f maxV=%.4f maxW=%.4f bounces=%d pinned=%s owner=%s stale=%.2f holds=%d woke=%s gone=%s", t.name, t.maxDrift,
		t.maxAngle, t.maxV, t.maxW, t.bounces, tostring(entry ~= nil and entry.ownerPinned == true), owner, t.stale or -1, entry and entry.restCount or 0, entry and tostring(entry.restWoke) or "-",
		t.goneAt and string.format("%.1f/%s/%s", t.goneAt, tostring(t.goneHealth), t.goneParent) or "no")
end
out("done %d rows", #tracked)
