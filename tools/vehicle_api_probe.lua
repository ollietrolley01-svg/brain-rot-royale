-- Vehicle API probe: confirms the Roblox behaviours the vehicle redesign depends on, before any
-- of it is built on them. Run in the background (it waits on the Studio lock):
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_api_probe.lua -OutDir <folder> -TimeoutSeconds 600
--
-- Run mode, isolated pads far from any map. Each check prints one PASS/FAIL line with the values
-- it saw, so a wrong assumption is visible rather than silently designed around.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local ORIGIN = Vector3.new(-9000, 600, -9000)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function check(name, ok, detail)
	note(string.format("%s %s | %s", ok and "PASS" or "FAIL", name, tostring(detail)))
end

local function pad(folder, position, size)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size or Vector3.new(60, 2, 60)
	part.CFrame = CFrame.new(position - Vector3.new(0, 1, 0))
	part.Parent = folder
	return part
end

local function part(folder, size, cframe, props)
	local p = Instance.new("Part")
	p.Size = size
	p.CFrame = cframe
	for key, value in pairs(props or {}) do
		p[key] = value
	end
	p.Parent = folder
	return p
end

return {
	{
		name = "vehicle_api_probe",
		settle = 1,
		hold = 1,
		setup = function(folder, camera)
			if not RunService:IsRunning() then
				RunService:Run()
			end
			task.wait(3)

			local template
			for _ = 1, 3 do
				local ok, model = pcall(function()
					return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
				end)
				if ok and model then
					template = model
					break
				end
				task.wait(2)
			end
			if not template then
				note("no rig, giving up")
				return
			end

			local function rigAt(position)
				local rig = template:Clone()
				rig:PivotTo(CFrame.new(position))
				rig.Parent = folder
				return rig, rig:FindFirstChildOfClass("Humanoid")
			end

			-- 1. Touch-sitting with CanTouch false, then scripted Sit.
			do
				local base = ORIGIN
				pad(folder, base)
				local seat = part(folder, Vector3.new(2.4, 0.4, 2.2), CFrame.new(base + Vector3.new(0, 1.2, 0)), {
					Anchored = true,
				})
				seat:Destroy()
				seat = Instance.new("VehicleSeat")
				seat.Size = Vector3.new(2.4, 0.4, 2.2)
				seat.CFrame = CFrame.new(base + Vector3.new(0, 1.2, 0))
				seat.Anchored = true
				seat.CanTouch = false
				seat.Parent = folder
				local rig, humanoid = rigAt(base + Vector3.new(0, 4.5, 0))
				task.wait(2.5)
				check("CanTouch=false blocks touch-sit", seat.Occupant == nil, "occupant after drop onto seat: " .. tostring(seat.Occupant))
				seat:Sit(humanoid)
				task.wait(0.5)
				check("Sit() works with CanTouch=false", seat.Occupant == humanoid, "occupant: " .. tostring(seat.Occupant))

				-- 7. Jump gets you out.
				humanoid.Jump = true
				task.wait(0.8)
				check("Jump leaves the seat", seat.Occupant == nil and not humanoid.Sit, "occupant " .. tostring(seat.Occupant) .. " sit " .. tostring(humanoid.Sit))
				rig:Destroy()
			end

			-- 2. Disabled seat and Sit().
			do
				local base = ORIGIN + Vector3.new(100, 0, 0)
				pad(folder, base)
				local seat = Instance.new("Seat")
				seat.Size = Vector3.new(2.4, 0.4, 2.2)
				seat.CFrame = CFrame.new(base + Vector3.new(0, 1.2, 0))
				seat.Anchored = true
				seat.Disabled = true
				seat.Parent = folder
				local rig, humanoid = rigAt(base + Vector3.new(4, 4, 0))
				task.wait(1)
				seat:Sit(humanoid)
				task.wait(0.5)
				check("Sit() on a Disabled seat", seat.Occupant == humanoid, "occupant: " .. tostring(seat.Occupant) .. " (informational)")
				rig:Destroy()
			end

			-- 3. Server writes to VehicleSeat throttle/steer.
			do
				local seat = Instance.new("VehicleSeat")
				seat.Anchored = true
				seat.CFrame = CFrame.new(ORIGIN + Vector3.new(200, 5, 0))
				seat.Parent = folder
				seat.ThrottleFloat = 0.5
				seat.SteerFloat = -0.25
				task.wait()
				local a = string.format("after float writes: Throttle %d ThrottleFloat %.2f Steer %d SteerFloat %.2f", seat.Throttle, seat.ThrottleFloat, seat.Steer, seat.SteerFloat)
				seat.Throttle = -1
				seat.Steer = 1
				task.wait()
				local b = string.format("after int writes: Throttle %d ThrottleFloat %.2f Steer %d SteerFloat %.2f", seat.Throttle, seat.ThrottleFloat, seat.Steer, seat.SteerFloat)
				check("VehicleSeat throttle/steer writable", seat.Throttle == -1 and seat.Steer == 1, a .. " || " .. b)
			end

			-- 4. Motor6D.Transform moves a wheel on an unanchored, unanimated assembly.
			do
				local base = ORIGIN + Vector3.new(300, 0, 0)
				pad(folder, base)
				local body = part(folder, Vector3.new(4, 1, 8), CFrame.new(base + Vector3.new(0, 3, 0)), { Anchored = false })
				local wheel = part(folder, Vector3.new(0.8, 2, 2), CFrame.new(base + Vector3.new(2.5, 2.5, -3)), {
					Anchored = false, Massless = true, CanCollide = false, Shape = Enum.PartType.Cylinder,
				})
				local motor = Instance.new("Motor6D")
				motor.Part0 = body
				motor.Part1 = wheel
				motor.C0 = body.CFrame:ToObjectSpace(wheel.CFrame)
				motor.Parent = body
				task.wait(1.5)
				local before = body.CFrame:ToObjectSpace(wheel.CFrame)
				motor.Transform = CFrame.new(0, -0.6, 0) * CFrame.Angles(math.rad(40), 0, 0)
				task.wait(0.1)
				local after = body.CFrame:ToObjectSpace(wheel.CFrame)
				local moved = (after.Position - before.Position).Magnitude
				check("Motor6D.Transform moves an unanimated part", moved > 0.3, string.format("offset moved %.2f studs", moved))
			end

			-- 5. VectorForce at an off-centre attachment rolls the body.
			do
				local base = ORIGIN + Vector3.new(400, 0, 0)
				local body = part(folder, Vector3.new(4, 1, 8), CFrame.new(base + Vector3.new(0, 40, 0)), { Anchored = false })
				local attach = Instance.new("Attachment")
				attach.Position = Vector3.new(2, 0, 0)
				attach.Parent = body
				local force = Instance.new("VectorForce")
				force.Attachment0 = attach
				force.RelativeTo = Enum.ActuatorRelativeTo.World
				force.ApplyAtCenterOfMass = false
				force.Force = Vector3.new(0, body.AssemblyMass * workspace.Gravity * 1.0, 0)
				force.Parent = body
				task.wait(0.6)
				local roll = math.deg(math.asin(math.clamp(body.CFrame.RightVector.Y, -1, 1)))
				local spin = body.AssemblyAngularVelocity.Magnitude
				check("off-centre VectorForce produces torque", spin > 0.2 or math.abs(roll) > 3, string.format("roll %.1f deg, angular speed %.2f", roll, spin))
			end

			-- 6. Seated rig mass and making it massless.
			do
				local base = ORIGIN + Vector3.new(500, 0, 0)
				pad(folder, base)
				local body = part(folder, Vector3.new(5, 1.5, 10), CFrame.new(base + Vector3.new(0, 1, 0)), { Anchored = false })
				local seat = Instance.new("VehicleSeat")
				seat.Size = Vector3.new(2.4, 0.4, 2.2)
				seat.CFrame = CFrame.new(base + Vector3.new(0, 2, 0))
				seat.Massless = true
				seat.Parent = folder
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = body
				weld.Part1 = seat
				weld.Parent = seat
				task.wait(0.8)
				local empty = body.AssemblyMass
				local rig, humanoid = rigAt(base + Vector3.new(4, 4, 0))
				task.wait(0.5)
				seat:Sit(humanoid)
				task.wait(0.8)
				local seated = body.AssemblyMass
				for _, p in ipairs(rig:GetDescendants()) do
					if p:IsA("BasePart") then
						p.Massless = true
					end
				end
				task.wait(0.3)
				local massless = body.AssemblyMass
				check("seated rig joins the assembly; Massless removes its mass", seated > empty + 1 and math.abs(massless - empty) < 0.5,
					string.format("empty %.1f, seated %.1f, rig massless %.1f (root part massless can't be)", empty, seated, massless))
				rig:Destroy()
			end

			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(250, 60, 140), ORIGIN + Vector3.new(250, 0, 0))
		end,
	},
}
