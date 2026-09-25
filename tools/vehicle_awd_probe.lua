-- All-wheel drive (Oliver 09-25: "the cars need awd"): what it changes, per car model, stepped the way
-- VehicleClient steps a driver's (VehicleDynamics.Step from RunService.Stepped), side by side:
--   drag   0 to 95% of top speed on a flat road slab, full throttle: seconds (AWD must not make a car
--          faster -- within 5% of before)
--   climb  from a standing start at the foot of a road ramp of each GRADE, full throttle: the steepest
--          it gets to the top of in 15 s (AWD should hold or raise it)
--   driven how many of its wheels the rig drives
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/vehicle_awd_probe.lua -PlaceFile <build>
-- Lines: "[AWD] <model> driven=N/M drag=S climb=DEG" and "[AWD] done".
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))

local function out(f, ...)
	print("[AWD] " .. string.format(f, ...))
end
if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(2)

local MODELS = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan", "TartarugaScout", "CameloCarrier" }
local GRADES = { 25, 30, 35, 40, 45, 50, 55 }
local OX, OY, OZ = -9000, 60, -9000
local folder = Instance.new("Folder")
folder.Name = "AwdProbe"
folder.Parent = workspace

local function slab(size, cf)
	local p = Instance.new("Part")
	p.Anchored, p.Size, p.CFrame, p.Material = true, size, cf, Enum.Material.Asphalt
	p.Parent = folder
	return p
end

local runs, lane = {}, 0
for _, id in ipairs(MODELS) do
	if VehicleModels.Models[id] and VehicleDynamics.Handling[id] then
		local kinds = { { kind = "drag" } }
		for _, grade in ipairs(GRADES) do
			table.insert(kinds, { kind = "climb", grade = grade })
		end
		for _, k in ipairs(kinds) do
			lane += 1
			local x = OX + lane * 24
			-- 600 studs of flat road, and on a climb lane a ramp from z = OZ - 20 rising at the grade for 40.
			slab(Vector3.new(20, 2, 600), CFrame.new(x, OY - 1, OZ - 280))
			if k.kind == "climb" then
				local rise = math.tan(math.rad(k.grade)) * 40
				local w = Instance.new("WedgePart")
				w.Anchored, w.Size, w.Material = true, Vector3.new(20, rise, 40), Enum.Material.Asphalt
				w.CFrame = CFrame.new(x, OY + rise / 2, OZ - 40) * CFrame.Angles(0, math.pi, 0)
				w.Parent = folder
				slab(Vector3.new(20, rise, 60), CFrame.new(x, OY + rise / 2, OZ - 90))
				k.top = OY + rise
			end
			local model = VehicleModels.Build(id, Random.new(7))
			model:PivotTo(CFrame.new(x, OY + 0.3, OZ + 6))
			model.Parent = folder
			local rig = VehicleDynamics.Rig(model)
			if rig then
				local driven = 0
				for _, wheel in ipairs(rig.wheels) do
					driven += wheel.drive and 1 or 0
				end
				table.insert(runs, { id = id, kind = k.kind, grade = k.grade, top = k.top, x = x, rig = rig, driven = driven })
			end
		end
	end
end
task.wait(1.5)

local startAt = tick()
local connection = RunService.Stepped:Connect(function(_, dt)
	for _, run in ipairs(runs) do
		if not run.done then
			local chassis = run.rig.chassis
			local cf = chassis.CFrame
			local forward = chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
			local steer = math.clamp(-(cf.Position.X - run.x) * 0.12 - cf.LookVector.X * 2.5, -1, 1)
			VehicleDynamics.Step(run.rig, { throttle = 1, steer = steer }, dt)
			local t = tick() - startAt
			if run.kind == "drag" and forward >= run.rig.handling.topSpeed * 0.95 then
				run.done, run.result = true, t
			elseif run.kind == "climb" and chassis.Position.Y >= run.top + 1 and (OZ - chassis.Position.Z) > 60 then
				run.done, run.result = true, t
			elseif t > (run.kind == "drag" and 25 or 15) then
				run.done = true
			end
			if run.done then
				VehicleDynamics.Idle(run.rig)
				chassis.Anchored = true
			end
		end
	end
end)
while tick() - startAt < 26 do
	task.wait(0.5)
end
connection:Disconnect()

for _, id in ipairs(MODELS) do
	local drag, climb, driven, wheels = -1, 0, 0, 0
	for _, run in ipairs(runs) do
		if run.id == id then
			driven, wheels = run.driven, #run.rig.wheels
			if run.kind == "drag" then
				drag = run.result or -1
			elseif run.result and run.grade > climb then
				climb = run.grade
			end
		end
	end
	out("%s driven=%d/%d drag=%.2f climb=%d", id, driven, wheels, drag, climb)
end
out("done")
