-- The client half of KillAnimService (#24): the death effect ("kill animation" in the code and the
-- save) a player has equipped, played on their victim. The server sends { id, position, body }:
-- `body` is the victim's character when the server has claimed it for the effect (anchored it, and
-- will hide it once the effect is over), and nil when it couldn't (a gun's own kill effect already
-- has it, or it's gone). The effects themselves, and the engine they run on, are in Shared
-- (DeathEffectDesigns, DeathEffectFx), because the shop's previews play the very same ones.
--
-- Budgets, on top of each effect's own part, particle and light caps (DeathEffectFx):
--   * at most MAX_LIVE effects at once; one past that is skipped, not queued
--   * nothing further than CULL_DISTANCE studs from the camera is built at all
--   * each effect is destroyed at its design's `life`, never over MAX_LIFETIME
-- A skipped or culled effect still takes care of its body: a claimed body is faded out here, cheaply,
-- so it never stands frozen until the server hides it.
-- tools/killanim_check.py runs this file, the engine and every design on a stand-in clock and checks
-- all of it, and that nothing is left running once an effect's folder is gone.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local DeathEffectFx = require(Shared:WaitForChild("DeathEffectFx"))
local Designs = require(Shared:WaitForChild("DeathEffectDesigns"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local killAnimFx = Remotes.Event("KillAnimFx")

local MAX_LIVE = 4
local MAX_LIFETIME = DeathEffectFx.MAX_LIFETIME
local CULL_DISTANCE = 260

-- How far below the body's root the ground usually is (root half-height plus hip height), used
-- when the ray down finds nothing but bodies.
local ROOT_TO_GROUND = 3

-- How long a skipped effect's body takes to fade.
local FALLBACK_FADE = 0.5

local V = Vector3.new

-- Running effects: { fx, t, life }, stepped every frame by one Heartbeat connection that exists only
-- while something is running. Time is the sum of frame deltas (not os.clock, which is CPU time).
local running = {}
local connection

--------------------------------------------------------------------------------
-- Stepping
--------------------------------------------------------------------------------

local function stepAll(dt)
	for index = #running, 1, -1 do
		local entry = running[index]
		entry.t += dt
		if entry.t >= entry.life then
			entry.fx:destroy()
			table.remove(running, index)
		else
			local ok, err = pcall(entry.fx.step, entry.fx, entry.t)
			if not ok then
				warn("[KillAnimFxClient] " .. entry.id .. ": " .. tostring(err))
				entry.fx:destroy()
				table.remove(running, index)
			end
		end
	end
	if #running == 0 and connection then
		connection:Disconnect()
		connection = nil
	end
end

local function start(entry)
	table.insert(running, entry)
	if not connection then
		connection = RunService.Heartbeat:Connect(stepAll)
	end
end

--------------------------------------------------------------------------------
-- Playing one
--------------------------------------------------------------------------------

-- The ground under the body. The ray skips every character and the body itself; if it still lands
-- on something with a Humanoid (a bot's body), or nothing, assume the usual height.
local function groundUnder(position, body)
	local skip = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(skip, other.Character)
		end
	end
	if body then
		table.insert(skip, body)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = skip
	local hit = workspace:Raycast(position, V(0, -12, 0), params)
	if hit and not (hit.Instance.Parent and hit.Instance.Parent:FindFirstChildOfClass("Humanoid")) then
		return hit.Position
	end
	return position - V(0, ROOT_TO_GROUND, 0)
end

-- A claimed body whose effect isn't being built here: faded out, no parts made. Stepped like an
-- effect so it's torn down the same way.
local function fadeBody(body, position)
	local fx = DeathEffectFx.new({ parent = workspace, name = "KillAnimFx", origin = position, life = FALLBACK_FADE,
		body = body, ownsBody = true })
	fx:tween(0, FALLBACK_FADE, function(e)
		fx:bodyPose({ fade = e })
	end, DeathEffectFx.Ease.quadIn)
	start({ fx = fx, t = 0, life = FALLBACK_FADE, id = "fade", cheap = true })
end

-- Effects running now, not counting body fades (they make no parts, so they don't count against
-- MAX_LIVE).
local function liveCount()
	local count = 0
	for _, entry in ipairs(running) do
		if not entry.cheap then
			count += 1
		end
	end
	return count
end

local function play(id, position, body)
	local design = Designs.Get(id)
	if not design then
		return
	end
	local camera = workspace.CurrentCamera
	local far = camera and (camera.CFrame.Position - position).Magnitude > CULL_DISTANCE
	if far or liveCount() >= MAX_LIVE then
		if body then
			fadeBody(body, position)
		end
		return
	end

	local life = math.min(design.life, MAX_LIFETIME)
	local fx = DeathEffectFx.new({
		parent = workspace,
		name = "KillAnimFx",
		origin = position,
		ground = groundUnder(position, body),
		life = life,
		body = body,
		ownsBody = body ~= nil,
		seed = math.random(1, 1000000),
		sound = function(cue, at, jitter)
			Sfx.PlayAt(cue, at, jitter)
		end,
	})
	local entry = { fx = fx, t = 0, life = life, id = id }
	local ok, err = pcall(design.build, fx)
	if ok then
		ok, err = pcall(fx.step, fx, 0)
	end
	if not ok then
		warn("[KillAnimFxClient] " .. id .. ": " .. tostring(err))
		fx:destroy()
		if body then
			fadeBody(body, position)
		end
		return
	end
	start(entry)
end

killAnimFx.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or type(data.id) ~= "string" or typeof(data.position) ~= "Vector3" then
		return
	end
	-- Only a Model still in the world counts as a body; anything else plays without one.
	local body = typeof(data.body) == "Instance" and data.body:IsA("Model") and data.body:IsDescendantOf(workspace) and data.body or nil
	play(data.id, data.position, body)
end)
