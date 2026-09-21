-- The shrinking zone. Walks the phases in MatchConfig, damaging anyone caught outside.
--
-- The wall itself is drawn client-side by StormClient from the StormChanged broadcasts. It
-- used to be built here as two server parts — a tall cylinder and a 6-stud "edge band" disc
-- spanning the entire safe zone — and since both were solid volumes, everyone inside the circle
-- saw a purple film across the whole ground that read as fog. Every radius change also
-- replicated a resize of both.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))

local StormService = {}

local stormChanged = Remotes.Event("StormChanged")

local running = false
local generation = 0

local state = {
	center = Vector3.zero,
	radius = 0,
	targetCenter = Vector3.zero,
	targetRadius = 0,
	phase = 0,
	damagePerSecond = 0,
	status = "Idle",
	secondsLeft = 0,
}

local mapRadius = 400

-- A Zone Rush match runs every phase's hold and shrink this much faster (MatchService sets it).
local speedScale = 1

function StormService.SetSpeed(scale)
	speedScale = math.max(0.25, scale or 1)
end

local function broadcast()
	stormChanged:FireAllClients({
		center = state.center,
		radius = state.radius,
		targetCenter = state.targetCenter,
		targetRadius = state.targetRadius,
		phase = state.phase,
		totalPhases = #MatchConfig.StormPhases,
		status = state.status,
		secondsLeft = math.max(0, math.floor(state.secondsLeft)),
		damagePerSecond = state.damagePerSecond,
		-- Additive, and nil for every battle royale broadcast: a static boundary (StartStatic)
		-- sends the line the HUD should show instead of the phase countdown, which means nothing
		-- for a circle that never moves.
		label = state.label,
	})
end

-- Next circle sits inside the current one, biased toward the middle so the endgame is
-- reachable from anywhere on the ring.
local function pickNextCenter(currentCenter, currentRadius, nextRadius)
	local drift = math.max(0, currentRadius - nextRadius) * 0.55
	local angle = math.random() * math.pi * 2
	local distance = math.sqrt(math.random()) * drift
	return currentCenter + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

function StormService.GetState()
	return state
end

function StormService.IsOutside(position)
	local flat = Vector3.new(position.X - state.center.X, 0, position.Z - state.center.Z)
	return flat.Magnitude > state.radius
end

function StormService.Stop()
	running = false
	generation += 1
	state.status = "Idle"
	state.damagePerSecond = 0
	-- A static boundary's label must not survive into the next match's storm.
	state.label = nil
	broadcast()
end

-- A boundary circle that NEVER shrinks: the playable arena for a mode with no storm.
--
-- Purely additive — Start and its phase walker are untouched. Everything a static circle needs is
-- already here: StormClient draws any non-Idle circle, the HUD minimap rings it, and BotService
-- reads GetState to decide when to rotate inside, so bots respect the arena with no bot change.
--
-- Status is "Final", not "Waiting". The original reason (BotService.stormPressure added a phase's
-- shrink time while "Waiting", so a static circle read as one closing in) is GONE — claude-af has
-- since fixed stormPressure properly: a circle that is neither Waiting nor Shrinking sets no
-- deadline, and only being outside it is urgent. "Final" is kept for what it still buys, which is
-- the client ring and minimap treatment of a settled circle rather than a closing one.
--
-- The damage tick below is a copy of the one in Start rather than a shared helper, deliberately:
-- factoring it out would mean editing Start, and the battle royale's storm path is not to change
-- by a byte.
function StormService.StartStatic(center, radius, damagePerSecond, label)
	StormService.Stop()
	if not center or not radius or radius <= 0 then
		return false
	end

	generation += 1
	local myGeneration = generation
	running = true

	state.center = Vector3.new(center.X, 0, center.Z)
	state.radius = radius
	state.targetCenter = state.center
	state.targetRadius = radius
	state.phase = 0
	state.status = "Final"
	state.secondsLeft = 0
	state.shrinkSeconds = 0
	state.damagePerSecond = damagePerSecond or 0
	state.label = label
	broadcast()

	task.spawn(function()
		while running and generation == myGeneration do
			task.wait(1)
			if state.damagePerSecond > 0 then
				for character in pairs(Combatants.All()) do
					if character.Parent then
						local humanoid = character:FindFirstChildOfClass("Humanoid")
						local root = character:FindFirstChild("HumanoidRootPart")
						if humanoid and root and humanoid.Health > 0 and StormService.IsOutside(root.Position) then
							humanoid:TakeDamage(state.damagePerSecond)
						end
					end
				end
			end
		end
	end)

	return true
end

function StormService.Start(radius)
	StormService.Stop()

	mapRadius = radius or mapRadius

	generation += 1
	local myGeneration = generation
	running = true

	state.center = Vector3.zero
	state.radius = mapRadius
	state.targetCenter = state.center
	state.targetRadius = state.radius
	state.phase = 0
	state.damagePerSecond = 0
	state.status = "Waiting"
	broadcast()

	task.spawn(function()
		for phaseIndex, phase in ipairs(MatchConfig.StormPhases) do
			if not running or generation ~= myGeneration then
				return
			end

			local phaseRadius = mapRadius * phase.radiusScale
			local holdTime = phase.holdTime / speedScale
			local shrinkTime = phase.shrinkTime / speedScale

			state.phase = phaseIndex
			-- Read by bots to judge how long they have to get inside (it's already scaled for Zone Rush).
			state.shrinkSeconds = shrinkTime
			state.damagePerSecond = phase.damagePerSecond
			state.targetRadius = phaseRadius
			state.targetCenter = pickNextCenter(state.center, state.radius, phaseRadius)

			state.status = "Waiting"
			local elapsed = 0
			while elapsed < holdTime do
				if not running or generation ~= myGeneration then
					return
				end
				state.secondsLeft = holdTime - elapsed
				broadcast()
				task.wait(1)
				elapsed += 1
			end

			state.status = "Shrinking"
			local fromCenter, fromRadius = state.center, state.radius
			local shrinkElapsed = 0
			while shrinkElapsed < shrinkTime do
				if not running or generation ~= myGeneration then
					return
				end
				local alpha = shrinkElapsed / shrinkTime
				state.center = fromCenter:Lerp(state.targetCenter, alpha)
				state.radius = fromRadius + (phaseRadius - fromRadius) * alpha
				state.secondsLeft = shrinkTime - shrinkElapsed
				broadcast()
				task.wait(0.5)
				shrinkElapsed += 0.5
			end

			state.center = state.targetCenter
			state.radius = phaseRadius
			broadcast()
		end

		state.status = "Final"
		broadcast()
	end)

	-- Damage tick, independent of the phase walker.
	task.spawn(function()
		while running and generation == myGeneration do
			task.wait(1)
			if state.damagePerSecond > 0 then
				-- Every combatant, not just real players. Iterating Players here left bots
				-- completely immune to the storm, so they'd never be pressured to rotate
				-- and could sit outside the final circle forever.
				for character in pairs(Combatants.All()) do
					if character.Parent then
						local humanoid = character:FindFirstChildOfClass("Humanoid")
						local root = character:FindFirstChild("HumanoidRootPart")
						if humanoid and root and humanoid.Health > 0 and StormService.IsOutside(root.Position) then
							humanoid:TakeDamage(state.damagePerSecond)
						end
					end
				end
			end
		end
	end)
end

return StormService
