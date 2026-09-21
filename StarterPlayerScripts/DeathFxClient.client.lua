-- The client half of DeathFxService: a sound at every body as its effect plays, and the shove
-- for our own body. A player's character is simulated by their own client, so the server can't
-- push it — it sends the velocity here and we apply it to whatever parts we still own.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local deathFx = Remotes.Event("DeathFx")

-- Effect (or moment within one) -> sound and pitch jitter.
local CUES = {
	ragdoll = { "BodyFall", 0.2 },
	float = { "FloatAway", 0.15 },
	ash = { "AshAway", 0.15 },
	burn = { "Burn", 0.2 },
	freeze = { "Freeze", 0.1 },
	shatter = { "Shatter", 0.2 },
	shock = { "Shock", 0.3 },
	confetti = { "Confetti", 0.2 },
	vaporize = { "Vaporize", 0.15 },
	gold = { "Gold", 0.1 },
	goldCrumble = { "GoldCrumble", 0.2 },
}

local function shoveOwnBody(data)
	local character = player.Character
	if not character or typeof(data.velocity) ~= "Vector3" then
		return
	end
	local scatter = tonumber(data.scatter) or 0
	local angular = tonumber(data.angular) or 0
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") and not part.Anchored then
			part.AssemblyLinearVelocity = data.velocity
				+ Vector3.new((math.random() - 0.5) * scatter, math.random() * scatter * 0.6, (math.random() - 0.5) * scatter)
			if angular > 0 then
				part.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8)) * angular
			end
		end
	end
end

deathFx.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" then
		return
	end
	if data.kind == "shove" then
		shoveOwnBody(data)
		return
	end
	local cue = CUES[data.kind]
	if cue and typeof(data.position) == "Vector3" then
		Sfx.PlayAt(cue[1], data.position, cue[2])
	end
end)
