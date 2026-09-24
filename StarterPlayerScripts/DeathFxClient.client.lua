-- The client half of DeathFxService: a sound at every body as its effect plays, the shove for our
-- own body, and the dressing on the plain death. A player's character is simulated by their own
-- client, so the server can't push it — it sends the velocity here and we apply it to whatever parts
-- we still own.
--
-- The plain death (a ragdoll: no death effect equipped by the killer, a storm death, a fall) gets two
-- small effects from Shared/DeathEffectDesigns, run on the same engine as the death effect cosmetics:
-- at the hit, a white flash over the body, a spit of rot sparks, a thud of dust and a little rot-soul
-- wisp rising out of it; and when the server starts fading the ragdoll, a soft puff where it lies, so
-- it goes rather than just thinning. Neither ever moves the body (the server's physics owns it), and
-- neither plays once a death effect has claimed the body (KillAnimService arrives a moment after).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local DeathEffectFx = require(Shared:WaitForChild("DeathEffectFx"))
local Designs = require(Shared:WaitForChild("DeathEffectDesigns"))
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

-- The plain death's dressing: at most this many at once (a grenade drops five), none further than
-- this from the camera, and a beat's wait first for a death effect to claim the body.
local MAX_DRESSED = 6
local DRESS_DISTANCE = 200
local CLAIM_WAIT = 0.1

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

--------------------------------------------------------------------------------
-- Dressing the plain death
--------------------------------------------------------------------------------

-- Running dressings, stepped by one Heartbeat connection that exists only while one runs. Time is the
-- sum of frame deltas.
local dressing = {}
local connection

local function stepAll(dt)
	for index = #dressing, 1, -1 do
		local entry = dressing[index]
		entry.t += dt
		if entry.t >= entry.life then
			entry.fx:destroy()
			table.remove(dressing, index)
		else
			local ok, err = pcall(entry.fx.step, entry.fx, entry.t)
			if not ok then
				warn("[DeathFxClient] " .. tostring(err))
				entry.fx:destroy()
				table.remove(dressing, index)
			end
		end
	end
	if #dressing == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

local function claimed(body)
	return body:GetAttribute("DeathFxClaimed") == true
end

-- One of Designs.Default's effects on `body`, unless it's been claimed, is gone, is too far, or too
-- many are running.
local function dress(design, body, position)
	if not body.Parent or claimed(body) or #dressing >= MAX_DRESSED then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - position).Magnitude > DRESS_DISTANCE then
		return
	end
	local fx = DeathEffectFx.new({
		parent = workspace,
		name = "DeathFxDressing",
		origin = position,
		life = design.life,
		body = body,
		ownsBody = false,
		seed = math.random(1, 1000000),
	})
	local ok, err = pcall(design.build, fx)
	if ok then
		ok, err = pcall(fx.step, fx, 0)
	end
	if not ok then
		warn("[DeathFxClient] " .. tostring(err))
		fx:destroy()
		return
	end
	table.insert(dressing, { fx = fx, t = 0, life = design.life })
	if not connection then
		connection = RunService.Heartbeat:Connect(stepAll)
	end
end

local function torsoPosition(body, fallback)
	local torso = body:FindFirstChild("UpperTorso") or body:FindFirstChild("Torso") or body:FindFirstChild("HumanoidRootPart")
	return torso and torso.Position or fallback
end

local function dressRagdoll(data)
	local body = data.body
	if typeof(body) ~= "Instance" or not body:IsA("Model") then
		return
	end
	task.delay(CLAIM_WAIT, function()
		dress(Designs.Default.Impact, body, torsoPosition(body, data.position))
	end)
	local linger = tonumber(data.linger)
	if linger and linger > CLAIM_WAIT then
		task.delay(linger, function()
			if body.Parent then
				dress(Designs.Default.Poof, body, torsoPosition(body, data.position))
			end
		end)
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
	if data.kind == "ragdoll" and typeof(data.position) == "Vector3" then
		dressRagdoll(data)
	end
end)
