-- Admin HUD (#52) flight mechanics. Required only by AdminHud.client.lua, which is the only thing
-- that ever calls Start() -- and it only does so after the server's AdminHello has told THIS client
-- it is the admin (inside `build()`; nothing outside `build()` touches this module). So this module
-- trusts its caller completely: it does no admin check of its own, because there is no path to it
-- that hasn't already gone through the real one in AdminService.lua.
--
-- Server-authoritative contract this rides on: AdminService.lua sets the `AdminFly` attribute on
-- the Player instance ONLY after `isAdmin(player)` passes there. This module and its caller never
-- decide WHO can fly -- they only decide what flying LOOKS like once the server has said yes.
--
-- Mechanics: BodyVelocity + BodyGyro on the HumanoidRootPart, humanoid.PlatformStand = true so the
-- humanoid state machine stops fighting them. Start() is idempotent -- it tears itself down first,
-- so calling it again on a new body (a respawn while still flagged) can never leak the old pair --
-- and Stop() is idempotent and safe to call on a body that was never started, or twice in a row.
-- tools/admin_fly_probe.lua drives this directly against synthetic dummy characters.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local AdminFly = {}

local FLY_SPEED = 60
local FLY_BOOST = 2.2
local FORCE = Vector3.new(1e5, 1e5, 1e5)
local TORQUE = Vector3.new(4e4, 4e4, 4e4)

local state = nil -- { humanoid, root, velocity, gyro, conn }

-- Debug seam for the probe's PERMANENT planted fault only: with this true, Stop() skips resetting
-- PlatformStand, exactly as if that one line had been deleted from real teardown. Never set outside
-- admin_fly_probe.lua; ships false.
AdminFly._DebugSkipPlatformStandReset = false

function AdminFly.IsActive()
	return state ~= nil
end

function AdminFly.Stop()
	if not state then
		return
	end
	local dying = state
	state = nil
	if dying.conn then
		dying.conn:Disconnect()
	end
	if dying.velocity and dying.velocity.Parent then
		dying.velocity:Destroy()
	end
	if dying.gyro and dying.gyro.Parent then
		dying.gyro:Destroy()
	end
	if not AdminFly._DebugSkipPlatformStandReset then
		if dying.humanoid and dying.humanoid.Parent then
			dying.humanoid.PlatformStand = false
		end
	end
end

-- Returns true if flight actually engaged.
function AdminFly.Start(character)
	AdminFly.Stop()
	if typeof(character) ~= "Instance" then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return false
	end

	humanoid.PlatformStand = true
	local velocity = Instance.new("BodyVelocity")
	velocity.Name = "BRR_AdminFlyVelocity"
	velocity.MaxForce = FORCE
	velocity.Velocity = Vector3.zero
	velocity.Parent = root
	local gyro = Instance.new("BodyGyro")
	gyro.Name = "BRR_AdminFlyGyro"
	gyro.MaxTorque = TORQUE
	gyro.P = 3000
	gyro.CFrame = root.CFrame
	gyro.Parent = root

	local entry = { humanoid = humanoid, root = root, velocity = velocity, gyro = gyro }
	state = entry

	entry.conn = RunService.Heartbeat:Connect(function()
		if state ~= entry or not entry.root.Parent or not entry.humanoid.Parent or entry.humanoid.Health <= 0 then
			if state == entry then
				AdminFly.Stop()
			end
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local camCF = camera.CFrame
		local move = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += Vector3.new(0, 0, -1) end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then move += Vector3.new(0, 0, 1) end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then move += Vector3.new(-1, 0, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += Vector3.new(1, 0, 0) end
		local vertical = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then vertical += 1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then vertical -= 1 end
		local boost = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and FLY_BOOST or 1

		local direction = (camCF.RightVector * move.X) + (camCF.LookVector * -move.Z) + Vector3.new(0, vertical, 0)
		entry.velocity.Velocity = (direction.Magnitude > 0.01 and direction.Unit or Vector3.zero) * FLY_SPEED * boost
		local flatLook = Vector3.new(camCF.LookVector.X, 0, camCF.LookVector.Z)
		if flatLook.Magnitude > 0.01 then
			entry.gyro.CFrame = CFrame.lookAt(entry.root.Position, entry.root.Position + flatLook)
		end
	end)
	return true
end

return AdminFly
