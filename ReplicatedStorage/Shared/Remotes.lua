local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()

local folder = ReplicatedStorage:FindFirstChild("Remotes")
if not folder then
	if IS_SERVER then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	else
		folder = ReplicatedStorage:WaitForChild("Remotes")
	end
end

local function get(className, name)
	local existing = folder:FindFirstChild(name)
	if existing then
		return existing
	end
	if IS_SERVER then
		local instance = Instance.new(className)
		instance.Name = name
		instance.Parent = folder
		return instance
	end
	return folder:WaitForChild(name)
end

local Remotes = {}

function Remotes.Event(name)
	return get("RemoteEvent", name)
end

function Remotes.Function(name)
	return get("RemoteFunction", name)
end

return Remotes
