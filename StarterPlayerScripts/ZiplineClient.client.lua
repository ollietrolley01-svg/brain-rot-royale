-- Riding a zipline (server: ZiplineService). The server has checked we're at the top and tells
-- us the line; from there our own character is moved along it, hanging under the rope, facing
-- the way it's going, until the bottom — or until we jump off.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local ride = Remotes.Event("Zipline")

local riding = nil

local function stopRide(letGo)
	local current = riding
	riding = nil
	if not current then
		return
	end
	if current.humanoid.Parent then
		current.humanoid.PlatformStand = false
	end
	if letGo and current.root.Parent then
		local direction = (current.to - current.from).Unit
		current.root.AssemblyLinearVelocity = Vector3.new(direction.X, 0, direction.Z) * current.speed * 0.45 + Vector3.new(0, 6, 0)
	end
	Sfx.Play("Zipline", 0.1, 0.8)
end

ride.OnClientEvent:Connect(function(data)
	if riding or type(data) ~= "table" or typeof(data.from) ~= "Vector3" or typeof(data.to) ~= "Vector3" then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return
	end
	riding = {
		from = data.from,
		to = data.to,
		length = math.max(1, (data.to - data.from).Magnitude),
		speed = tonumber(data.speed) or 50,
		hang = tonumber(data.hang) or 4.4,
		t = 0,
		humanoid = humanoid,
		root = root,
	}
	humanoid.PlatformStand = true
	root.AssemblyLinearVelocity = Vector3.zero
	Sfx.Play("Zipline", 0.1)
end)

RunService.Heartbeat:Connect(function(dt)
	local current = riding
	if not current then
		return
	end
	if not current.root.Parent or current.humanoid.Health <= 0 then
		stopRide(false)
		return
	end
	current.t = math.min(1, current.t + dt * current.speed / current.length)
	local position = current.from:Lerp(current.to, current.t) - Vector3.new(0, current.hang, 0)
	local direction = current.to - current.from
	local flat = Vector3.new(direction.X, 0, direction.Z)
	local look = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, -1)
	current.root.CFrame = CFrame.lookAt(position, position + look)
	current.root.AssemblyLinearVelocity = Vector3.zero
	current.root.AssemblyAngularVelocity = Vector3.zero
	if current.t >= 1 then
		stopRide(true)
	end
end)

UserInputService.JumpRequest:Connect(function()
	if riding then
		stopRide(true)
	end
end)
