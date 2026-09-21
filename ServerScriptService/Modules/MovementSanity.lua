-- Movement sanity: what the SERVER sees of each player's body, against what the server itself allowed.
--
-- IT ONLY COUNTS. It never kicks, never teleports anyone back, never clamps a speed, and never touches
-- gameplay in any way. Everything it reads is pcalled, and `MovementSanity.Enabled = false` turns the
-- whole thing off. If it is ever wrong, the worst it can do is print a number.
--
-- A player's character is simulated on their own machine, so nothing here (or anywhere else in this
-- project) can stop a modified client moving as it likes. What this does is notice: it samples the
-- replicated root position ten times a second and compares the distance covered with the distance the
-- server's own numbers allow —
--   * humanoid.WalkSpeed, which is exactly what MatchService.applySpeed composed (base x match event x
--     boost x sprint x slide x status effects),
--   * the jump speed on the humanoid (Bounce Boots raise it),
--   * plus any GRANT the server handed out: a Rot Rocket, a Launch Pad, a blast, a blink, a glider, a
--     zipline, a spring, a geyser. Whoever issues one calls Grant, and it decays on its own.
--   * a vehicle seat raises the allowance to that vehicle's top speed.
-- Teleports the SERVER performs (spawn placement, the lobby, a blink, a showcase) are not violations, so
-- whoever performs one calls Expect and the samples across it are skipped.
--
-- False positives are what make a monitor like this useless, so:
--   * the allowance scales with the real gap between samples, which absorbs lag and catch-up;
--   * excess goes into a leaky bucket (drains at DrainRate) and only a SUSTAINED overrun trips it, so one
--     spike never does;
--   * it is quiet while a body is dead, ragdolled, dropping in under a canopy, seated without a vehicle,
--     or inside the grace after a spawn or an Expect;
--   * it runs only for participants of a running match.
--
-- tools/movement_probe.lua drives it both ways: a legit pass (sprint, slide, rocket, glider, blink,
-- vehicle) that must count ZERO and prints the worst legit excess as the margin, and planted faults
-- (a sustained 2.5x walk, and repeated 40-stud teleports with no Expect) that must be counted.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local MovementSanity = {}

MovementSanity.Enabled = true

-- Tuning. Tune from the probe's margin, not from taste.
MovementSanity.Tuning = {
	-- Samples per second.
	Rate = 10,
	-- How much over the composed speed is still "normal": network bunching, a frame of extrapolation.
	Margin = 1.35,
	-- Studs per second of slack on top (NOT per sample: at 10 Hz a 4-stud per-sample slack would have
	-- allowed 40 studs/s of free speed).
	Slack = 6,
	-- How fast the expected speed is allowed to fall away when the server cuts it (studs/s per second).
	-- A humanoid brakes from a sprint in about a fifth of a second, so this is comfortably quicker than
	-- any legitimate deceleration without leaving a window worth exploiting.
	CoastDown = 60,
	-- Excess studs the bucket holds before it counts a violation, and how fast it empties.
	Bucket = 40,
	DrainRate = 10,
	-- Quiet for this long after a spawn, an Expect or a character change.
	Grace = 1,
	-- A seat with no known vehicle speed still allows this much.
	SeatSpeed = 100,
	-- A canopy overhead (the drop-in or a Rot Glider) allows this much on its own.
	CanopySpeed = 48,
	-- At most one warning per player per this many seconds.
	WarnInterval = 10,
}

-- Set by Bootstrap so this module needs no other service: is the match running, and is this token in it.
MovementSanity.IsActive = function()
	return true
end
-- Optional: the top speed of the vehicle a seat belongs to.
MovementSanity.SeatSpeed = function()
	return nil
end

local T = MovementSanity.Tuning

-- key (Player, or any key for a probe) -> state
local watched = {}
-- key -> { speed, untilTime }
local grants = {}
-- key -> os.clock() until which samples are skipped, for an Expect that arrived before the first sample
local pendingQuiet = {}

local function stateFor(key, character)
	local entry = watched[key]
	if not entry then
		entry = {
			character = character,
			lastPosition = nil,
			lastAt = 0,
			quietUntil = math.max(os.clock() + T.Grace, pendingQuiet[key] or 0),
			bucket = 0,
			violations = 0,
			samples = 0,
			worstExcess = 0,
			totalExcess = 0,
			lastKind = nil,
			warnedAt = 0,
			name = typeof(key) == "Instance" and key.Name or tostring(key),
		}
		watched[key] = entry
		pendingQuiet[key] = nil
	elseif entry.character ~= character then
		-- A new body for the same player: the counts stay (they're per player, per match), the position
		-- history doesn't.
		entry.character = character
		entry.lastPosition = nil
		entry.bucket = 0
		entry.quietUntil = os.clock() + T.Grace
	end
	return entry
end

--------------------------------------------------------------------------------
-- What the server handed out
--------------------------------------------------------------------------------

-- `speed` studs/s of extra allowance for `seconds` (a launch, a glide, a zipline ride). The strongest
-- grant still running is the one that counts.
function MovementSanity.Grant(key, speed, seconds)
	if not MovementSanity.Enabled or key == nil then
		return
	end
	if type(speed) ~= "number" or speed ~= speed or speed <= 0 then
		return
	end
	local untilTime = os.clock() + math.clamp(type(seconds) == "number" and seconds or 3, 0, 30)
	local current = grants[key]
	if current and current.untilTime > os.clock() and current.speed > speed then
		current.untilTime = math.max(current.untilTime, untilTime)
		return
	end
	grants[key] = { speed = math.min(speed, 500), untilTime = untilTime }
end

-- The server is about to move this body itself (spawn, lobby, blink, showcase): don't read the jump.
function MovementSanity.Expect(key, seconds)
	if not MovementSanity.Enabled or key == nil then
		return
	end
	local quietUntil = os.clock() + math.clamp(type(seconds) == "number" and seconds or T.Grace, 0, 10)
	local entry = watched[key]
	if entry then
		entry.lastPosition = nil
		entry.quietUntil = math.max(entry.quietUntil, quietUntil)
	else
		-- Before this body's first sample: remembered, so the first comparison is skipped too.
		pendingQuiet[key] = math.max(pendingQuiet[key] or 0, quietUntil)
	end
end

-- For probes: watch any body, not just a player's.
function MovementSanity.Watch(key, character)
	if key == nil or typeof(character) ~= "Instance" then
		return
	end
	stateFor(key, character).extra = true
end

function MovementSanity.Unwatch(key)
	watched[key] = nil
	grants[key] = nil
	pendingQuiet[key] = nil
end

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

local SKIP_STATES = {
	[Enum.HumanoidStateType.Dead] = true,
	[Enum.HumanoidStateType.Ragdoll] = true,
	[Enum.HumanoidStateType.FallingDown] = true,
	[Enum.HumanoidStateType.Physics] = true,
	[Enum.HumanoidStateType.PlatformStanding] = true,
}

-- One body, one sample. Returns the excess studs this sample (0 when it's within the allowance), or nil
-- when the sample was skipped.
local function sample(key, character, now)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or humanoid.Health <= 0 then
		return nil
	end
	local entry = stateFor(key, character)
	if now < entry.quietUntil then
		entry.lastPosition = nil
		return nil
	end
	if SKIP_STATES[humanoid:GetState()] then
		entry.lastPosition = nil
		return nil
	end
	-- Under a canopy (the match drop-in or a Rot Glider) the body is flying by design.
	local canopy = character:FindFirstChild("GliderCanopy") ~= nil

	local position = root.Position
	local last, lastAt = entry.lastPosition, entry.lastAt
	entry.lastPosition, entry.lastAt = position, now
	if not last then
		return nil
	end
	local dt = now - lastAt
	if dt <= 0 or dt > 1 then
		return nil
	end

	local speed = humanoid.WalkSpeed
	if humanoid.Sit then
		local seat = humanoid.SeatPart
		local seatSpeed = nil
		if seat then
			local ok, value = pcall(MovementSanity.SeatSpeed, seat)
			seatSpeed = ok and type(value) == "number" and value or nil
		end
		speed = math.max(speed, seatSpeed or T.SeatSpeed)
	end
	local grant = grants[key]
	if grant then
		if grant.untilTime < now then
			grants[key] = nil
		else
			speed = math.max(speed, grant.speed)
		end
	end
	if canopy then
		speed = math.max(speed, T.CanopySpeed)
	end

	-- A body can't accelerate past its allowance, but it can still be COASTING DOWN from one the server
	-- itself gave it a moment ago: crouching out of a run, a sprint ending, a slide's ceiling expiring, a
	-- chill landing. WalkSpeed drops on the instant; the body takes a fraction of a second to follow.
	-- Without this every honest player who crouches out of a run collects strikes, and the ones who
	-- deserve them get harder to see. The ceiling is never above a speed the server actually assigned,
	-- and it falls away at CoastDown, so this costs nothing in what it catches.
	local ceiling = entry.speedCeiling or speed
	if speed >= ceiling then
		ceiling = speed
	else
		ceiling = math.max(speed, ceiling - T.CoastDown * dt)
	end
	entry.speedCeiling = ceiling
	speed = ceiling

	local horizontal = (Vector3.new(position.X, 0, position.Z) - Vector3.new(last.X, 0, last.Z)).Magnitude
	local rise = math.max(position.Y - last.Y, 0)
	local allowance = (speed * T.Margin + T.Slack) * dt
	local jumpSpeed = humanoid.UseJumpPower and humanoid.JumpPower
		or math.sqrt(2 * workspace.Gravity * math.max(humanoid.JumpHeight, 0))
	local riseAllowance = (math.max(jumpSpeed, speed) * T.Margin + T.Slack) * dt

	local excess = math.max(horizontal - allowance, 0) + math.max(rise - riseAllowance, 0)
	entry.samples += 1
	if excess > entry.worstExcess then
		entry.worstExcess = excess
		entry.lastKind = horizontal - allowance > rise - riseAllowance and "horizontal" or "vertical"
	end
	entry.totalExcess += excess
	entry.bucket = math.clamp(entry.bucket + excess - T.DrainRate * dt, 0, T.Bucket * 3)
	if entry.bucket >= T.Bucket then
		entry.bucket = 0
		entry.violations += 1
		if now - entry.warnedAt >= T.WarnInterval then
			entry.warnedAt = now
			warn(string.format("[MovementSanity] %s is moving further than the server allowed: %d so far, worst %.1f studs over in one sample (%s). Counting only.",
				entry.name, entry.violations, entry.worstExcess, tostring(entry.lastKind)))
		end
	end
	return excess
end

local accumulated = 0
RunService.Heartbeat:Connect(function(delta)
	if not MovementSanity.Enabled then
		return
	end
	accumulated += delta
	if accumulated < 1 / T.Rate then
		return
	end
	accumulated = 0
	local now = os.clock()
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local ok, active = pcall(MovementSanity.IsActive, player)
		if character and ok and active then
			pcall(sample, player, character, now)
		elseif watched[player] then
			watched[player].lastPosition = nil
		end
	end
	for key, entry in pairs(watched) do
		if entry.extra and entry.character and entry.character.Parent then
			pcall(sample, key, entry.character, now)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	watched[player] = nil
	grants[player] = nil
	pendingQuiet[player] = nil
end)

--------------------------------------------------------------------------------
-- Reading it back
--------------------------------------------------------------------------------

-- { [name] = { violations, samples, worstExcess, totalExcess, lastKind } }, plus totals.
function MovementSanity.GetReport()
	local report = { bodies = {}, violations = 0, worstExcess = 0, samples = 0 }
	for _, entry in pairs(watched) do
		report.bodies[entry.name] = {
			violations = entry.violations,
			samples = entry.samples,
			worstExcess = entry.worstExcess,
			totalExcess = entry.totalExcess,
			lastKind = entry.lastKind,
		}
		report.violations += entry.violations
		report.samples += entry.samples
		report.worstExcess = math.max(report.worstExcess, entry.worstExcess)
	end
	return report
end

function MovementSanity.Reset(key)
	if key then
		watched[key] = nil
		grants[key] = nil
		pendingQuiet[key] = nil
		return
	end
	watched = {}
	grants = {}
	pendingQuiet = {}
end

return MovementSanity
