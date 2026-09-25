-- All-wheel drive bug test (47200d3), the part lupa can't settle: the same runs as
-- tools/awd_bugtest_check.py's "step" part, with Roblox's own physics, each car twice side by side:
--   awd   the drive as shipped on main
--   pre   the centre split put back to the load share (VehicleDynamics.DriveSplit swapped for the length
--         of each Step call), and Rotster/TralalaGT/SahurVan back on the wheels they drove before 47200d3
--         (Handling.driven set before Rig). NOT the whole of 47200d3^: the per-wheel cap is a local in
--         Step and stays on. For the Ranger, Scout and Carrier it is the old split exactly unless a wheel
--         would take more than half the drive.
-- Runs, each on its own lane of flat asphalt:
--   crawl  12 studs/s, full lock, throttle 0.15 for 5 s (the bot's corners in tools/bot_driving_sim.py):
--          turning radius and speed over the last 2 s
--   jump   70 studs/s off a 20-degree, 14-stud wedge, throttle 1: airtime, relaunch after landing, the
--          highest pitch rate within 1 s of landing, the lowest the body's up vector points
--   drag   from rest, throttle 1 for 25 s: seconds to 95% of Handling topSpeed (-1 = never), the top reached,
--          and the body's mean tilt from level over the first 2 s (the van and carrier sit nose-up)
--
--   A real Play test with a client (coordinator's 2026-09-25-0435 message: runtest's Run mode doesn't
--   count for vehicles), with this as a server script or through tools/runtest.ps1 -Probe on Play.
--   Not run by the author: no Studio on that machine.
-- Lines: "[AWDBUG] <model> <variant> <run> k=v ..." and "[AWDBUG] done".
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))

local function out(f, ...)
	print("[AWDBUG] " .. string.format(f, ...))
end

local MODELS = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan", "TartarugaScout", "CameloCarrier" }
local BEFORE_DRIVEN = { Rotster = "front", TralalaGT = "rear", SahurVan = "rear" }
local RUNS = {
	crawl = { speed = 12, throttle = 0.15, steer = 1, time = 5 },
	jump = { speed = 70, throttle = 1, steer = 0, time = 4, wedge = true },
	drag = { speed = 0, throttle = 1, steer = 0, time = 25 },
}
local ORDER = { "crawl", "jump", "drag" }
local OX, OY, OZ = -12000, 60, -12000

local shippedSplit = VehicleDynamics.DriveSplit
-- The split before 47200d3: each axle by the load on it.
local function loadShare(frontLoad, rearLoad)
	local total = frontLoad + rearLoad
	return total > 0 and math.max(frontLoad, 0) / total or 0
end

local folder = Instance.new("Folder")
folder.Name = "AwdBugtestProbe"
folder.Parent = workspace

local function slab(size, cf)
	local p = Instance.new("Part")
	p.Anchored, p.Size, p.CFrame, p.Material = true, size, cf, Enum.Material.Asphalt
	p.Parent = folder
	return p
end

task.wait(2)
local runs, lane = {}, 0
for _, id in ipairs(MODELS) do
	if VehicleModels.Models[id] and VehicleDynamics.Handling[id] then
		for _, variant in ipairs({ "awd", "pre" }) do
			for _, name in ipairs(ORDER) do
				local spec = RUNS[name]
				lane += 1
				local x = OX + lane * 100
				-- 1,400 studs of flat road running -Z from the start; a crawl circles within 45 of it.
				slab(Vector3.new(90, 2, 1400), CFrame.new(x, OY - 1, OZ - 680))
				if spec.wedge then
					local rise = math.tan(math.rad(20)) * 14
					local w = Instance.new("WedgePart")
					w.Anchored, w.Size, w.Material = true, Vector3.new(20, rise, 14), Enum.Material.Asphalt
					w.CFrame = CFrame.new(x, OY + rise / 2, OZ - 60) * CFrame.Angles(0, math.pi, 0)
					w.Parent = folder
				end
				local handling = VehicleDynamics.Handling[id]
				local shipped = handling.driven
				if variant == "pre" and BEFORE_DRIVEN[id] then
					handling.driven = BEFORE_DRIVEN[id]
				end
				local model = VehicleModels.Build(id, Random.new(7))
				model:PivotTo(CFrame.new(x, OY + 0.3, OZ + 6))
				model.Parent = folder
				local rig = VehicleDynamics.Rig(model)
				handling.driven = shipped
				if rig then
					table.insert(runs, { id = id, variant = variant, name = name, spec = spec, x = x, rig = rig,
						t = 0, air = 0, airMax = 0, landedAt = nil, relaunch = 0, pitchMax = 0, minUp = 1,
						tilt = 0, tiltN = 0, t95 = -1, top = 0, tail = {} })
				end
			end
		end
	end
end
task.wait(1.5)

for _, run in ipairs(runs) do
	local chassis = run.rig.chassis
	chassis.AssemblyLinearVelocity = chassis.CFrame.LookVector * run.spec.speed
end

local connection = RunService.Stepped:Connect(function(_, dt)
	for _, run in ipairs(runs) do
		if not run.done then
			local chassis = run.rig.chassis
			local cf = chassis.CFrame
			local spec = run.spec
			VehicleDynamics.DriveSplit = run.variant == "pre" and loadShare or shippedSplit
			local tel = VehicleDynamics.Step(run.rig, { throttle = spec.throttle, steer = spec.steer }, dt)
			VehicleDynamics.DriveSplit = shippedSplit
			run.t += dt
			local v = chassis.AssemblyLinearVelocity
			local forward = v:Dot(cf.LookVector)
			local w = chassis.AssemblyAngularVelocity
			if run.name == "crawl" and run.t >= spec.time - 2 then
				table.insert(run.tail, { speed = Vector3.new(v.X, 0, v.Z).Magnitude, yaw = math.abs(w:Dot(cf.UpVector)) })
			elseif run.name == "jump" then
				if tel.grounded == 0 then
					run.air += dt
					if run.landedAt then
						run.relaunch += dt
					end
				else
					if not run.landedAt and run.air >= 0.1 then
						run.landedAt, run.airMax = run.t, run.air
					end
					if not run.landedAt then
						run.air = 0
					end
				end
				if run.landedAt then
					if run.t - run.landedAt <= 1 then
						run.pitchMax = math.max(run.pitchMax, math.abs(w:Dot(cf.RightVector)))
					end
					run.minUp = math.min(run.minUp, cf.UpVector.Y)
				end
			elseif run.name == "drag" then
				run.top = math.max(run.top, forward)
				if run.t95 < 0 and forward >= run.rig.handling.topSpeed * 0.95 then
					run.t95 = run.t
				end
				if run.t <= 2 then
					run.tilt += math.deg(math.acos(math.clamp(cf.UpVector.Y, -1, 1)))
					run.tiltN += 1
				end
			end
			if run.t >= spec.time then
				run.done = true
				VehicleDynamics.Idle(run.rig)
				chassis.Anchored = true
			end
		end
	end
end)

local startAt = tick()
while tick() - startAt < 27 do
	task.wait(0.5)
end
connection:Disconnect()
VehicleDynamics.DriveSplit = shippedSplit

for _, run in ipairs(runs) do
	if run.name == "crawl" then
		local speed, yaw = 0, 0
		for _, sample in ipairs(run.tail) do
			speed += sample.speed
			yaw += sample.yaw
		end
		local n = math.max(#run.tail, 1)
		out("%s %s crawl radius=%.2f speed=%.2f", run.id, run.variant, yaw > 0 and speed / yaw or -1, speed / n)
	elseif run.name == "jump" then
		out("%s %s jump landed=%s air=%.2f relaunch=%.2f pitch=%.2f minUp=%.3f", run.id, run.variant,
			tostring(run.landedAt ~= nil), run.airMax, run.relaunch, run.pitchMax, run.minUp)
	else
		out("%s %s drag t95=%.2f top=%.2f tilt=%.2f", run.id, run.variant, run.t95, run.top,
			run.tiltN > 0 and run.tilt / run.tiltN or -1)
	end
end
out("done")
