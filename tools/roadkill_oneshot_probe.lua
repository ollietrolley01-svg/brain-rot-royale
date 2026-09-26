-- Task 30 (roadkill one-shot a full player), with real physics: Run mode, a car driven by a seated bot rig
-- at a standing bot rig with 100 health and a 100 shield (a bot keeps its shield on the humanoid's
-- "Shield" attribute, which DealDamage soaks first), on a flat slab far from everything.
--   python tools/linux/studio.py runtest -Probe tools/roadkill_oneshot_probe.lua -WaitSeconds 400
--   python tools/linux/studio.py gallery -Gallery tools/roadkill_oneshot_probe.lua -OutDir <dir>
-- Under the gallery the rows run as above, then the CLIP row's hit is replayed frame by frame: every part
-- of the car, its rider and the target is recorded each physics frame of the real run, then posed on
-- anchored copies one view at a time (a gallery view takes ~0.4 s, a hit a few frames), with the target's
-- health and shield drawn over it. brr-proof gif stitches the views.
--
-- The car's speed is written every frame through the hit and for HOLD seconds after it, so it meets the
-- body at 1x, 1.5x and 2x its top speed (what a ramp, a slope or a blast could do; the governor would
-- otherwise drag it back) and stays on the body's line in case physics brings them together again. Every
-- Roadkill DealDamage on the victim is logged: its time after the first, and what it took.
--
-- Lines start "[ONESHOT]". "PROBLEM" means a full target died or lost more than PASS_MAX in one pass. The
-- planted fault is the same probe on a build without the cap (pc/lag-bug-sweep cf35aa3): it must print
-- PROBLEM lines, or these rows prove nothing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local VehicleService = require(modules:WaitForChild("VehicleService"))
local Combatants = require(modules:WaitForChild("Combatants"))
local CombatService = require(modules:WaitForChild("CombatService"))
local VehicleDynamics = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("VehicleDynamics"))

local TAG = "[ONESHOT]"
local PASS_MAX = 150
local CX, CZ = 3200, 2600
local RUNUP = 180
local HOLD = 1.5

local function out(format, ...)
	print(TAG .. " " .. string.format(format, ...))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(3)
out("start: Run mode %s", tostring(RunService:IsRunning()))

local folder = Instance.new("Folder")
folder.Name = "RoadkillOneShotProbe"
folder.Parent = workspace
VehicleService.Start()
-- The sweep gates DealDamage on combat being on (MatchService turns it on for a match).
CombatService.SetEnabled(true)

-- Every Roadkill hit, as DealDamage answers it (VehicleService calls it through the module table).
local hits = {}
local deal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	local dealt = deal(attacker, victim, amount, weaponId, headshot)
	if weaponId == "Roadkill" then
		table.insert(hits, { victim = victim, dealt = dealt, at = os.clock() })
	end
	return dealt
end

local function makeRig(name, position)
	for _ = 1, 5 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			model.Name = name
			model.Parent = folder
			model:PivotTo(CFrame.new(position))
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			humanoid.BreakJointsOnDeath = false
			local token = { isBot = true, name = name, character = model }
			Combatants.Register(model, token)
			return model, humanoid, token
		end
		task.wait(0.4)
	end
	return nil
end

-- Anchored copies of `models` to pose a recording on, and the parts paired: parts[i] is posed as copies' posed[i].
local function copiesOf(models)
	local parts, posed, copies = {}, {}, {}
	for _, m in ipairs(models) do
		m.Archivable = true
		local copy = m:Clone()
		local from, to = m:GetDescendants(), copy:GetDescendants()
		for i, item in ipairs(from) do
			local twin = to[i]
			if item:IsA("BasePart") and twin and twin:IsA("BasePart") and twin.Name == item.Name then
				twin.Anchored = true
				twin.CanCollide = false
				table.insert(parts, item)
				table.insert(posed, twin)
			end
		end
		for _, item in ipairs(to) do
			if item:IsA("Humanoid") then
				item.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			elseif item:IsA("ProximityPrompt") or item:IsA("BaseScript") then
				item:Destroy()
			end
		end
		table.insert(copies, copy)
	end
	return parts, posed, copies
end

local lane = 0
local function run(modelId, speed, record)
	lane += 1
	local x = CX + lane * 60
	local slab = Instance.new("Part")
	slab.Anchored = true
	slab.Size = Vector3.new(40, 4, 900)
	slab.Position = Vector3.new(x, -2, CZ)
	slab.Parent = folder
	local startZ = CZ + 400
	local bodyZ = startZ - RUNUP
	local kind = modelId == "BrrStreetfighter" and "bike" or "car"
	local model = VehicleService.Create(folder, Vector3.new(x, 4, startZ), 0, kind, { model = modelId, exact = true })
	local chassis = model:FindFirstChild("Chassis")
	local seat = model:FindFirstChildOfClass("VehicleSeat")
	local driver, driverHumanoid = makeRig("OneShotDriver", seat.Position + Vector3.new(0, 3, 0))
	local victim, humanoid, token = makeRig("OneShotVictim", Vector3.new(x, 3.2, bodyZ))
	local function cleanup()
		for _, item in ipairs({ model, driver, victim, slab }) do
			if item then
				item:Destroy()
			end
		end
	end
	if not (driver and victim) then
		cleanup()
		return nil, "no rig"
	end
	seat:Sit(driverHumanoid)
	humanoid:SetAttribute("Shield", 100)
	task.wait(1.5)
	local throttle = RunService.Heartbeat:Connect(function()
		seat.ThrottleFloat = 1
		seat.SteerFloat = 0
	end)
	local first = nil
	local started = os.clock()
	local topSeen = 0
	local frames, parts, posed, copies = {}, nil, nil, nil
	if record then
		parts, posed, copies = copiesOf({ model, driver, victim })
	end
	while os.clock() - started < 12 do
		local v = chassis.AssemblyLinearVelocity
		chassis.AssemblyLinearVelocity = Vector3.new(0, v.Y, -speed)
		topSeen = math.max(topSeen, Vector3.new(v.X, 0, v.Z).Magnitude)
		for _, hit in ipairs(hits) do
			if hit.victim == token and not first then
				first = hit.at
			end
		end
		if first and os.clock() - first > HOLD then
			break
		end
		-- The clip: from 40 studs out to 0.6 s after the hit.
		if parts and chassis.Position.Z - bodyZ < 40 and (not first or os.clock() - first < 0.6) then
			local pose = {}
			for i, part in ipairs(parts) do
				pose[i] = part.CFrame
			end
			table.insert(frames, { pose = pose, health = humanoid.Health, shield = humanoid:GetAttribute("Shield") or 0 })
		end
		RunService.Heartbeat:Wait()
	end
	throttle:Disconnect()
	task.wait(0.5)
	local rows, total = {}, 0
	for _, hit in ipairs(hits) do
		if hit.victim == token then
			total += hit.dealt
			table.insert(rows, string.format("+%.2fs %d", hit.at - first, hit.dealt))
		end
	end
	local result = {
		health = humanoid.Health,
		shield = humanoid:GetAttribute("Shield") or 0,
		total = total,
		rows = rows,
		speedSeen = topSeen,
		hit = first ~= nil,
	}
	if record then
		-- The end state, held as the last frame.
		table.insert(frames, { pose = frames[#frames] and frames[#frames].pose, health = result.health, shield = result.shield })
		result.clip = { frames = frames, copies = copies, posed = posed, bodyAt = Vector3.new(x, 3, bodyZ) }
	end
	cleanup()
	return result
end

local problems, rowsRun = 0, 0
for _, case in ipairs({
	{ "BrrStreetfighter", 1 }, { "BrrStreetfighter", 1.5 }, { "BrrStreetfighter", 2 },
	{ "TralalaGT", 1.5 }, { "TralalaGT", 2 }, { "Rotster", 2 }, { "PatapimScrambler", 2 },
}) do
	local modelId, mult = case[1], case[2]
	local speed = VehicleDynamics.Handling[modelId].topSpeed * mult
	local ok, result, why = pcall(run, modelId, speed, false)
	if not ok or not result then
		out("PROBLEM %s %.1fx: the run failed: %s", modelId, mult, tostring(ok and why or result))
		problems += 1
	elseif not result.hit then
		out("PROBLEM %s %.1fx (%.0f): the car never hit the body", modelId, mult, speed)
		problems += 1
	else
		rowsRun += 1
		local taken = (100 - result.health) + (100 - result.shield)
		out("ROW %s %.1fx (%.0f studs/s, fastest read %.0f): hits [%s], took %.1f of 200, health %.1f shield %.1f%s",
			modelId, mult, speed, result.speedSeen, table.concat(result.rows, ", "), taken, result.health, result.shield,
			result.health <= 0 and " DEAD" or "")
		if result.health <= 0 or taken > PASS_MAX + 0.5 then
			out("PROBLEM %s %.1fx: a full target lost %.1f in one pass (health %.1f)", modelId, mult, taken, result.health)
			problems += 1
		end
	end
end

out("done: %d rows run, %d problems", rowsRun, problems)

--------------------------------------------------------------------------------
-- The clip (gallery only; a runtest ignores what this returns)
--------------------------------------------------------------------------------
local CLIP_MODEL, CLIP_MULT = "BrrStreetfighter", 1.5
local clipSpeed = VehicleDynamics.Handling[CLIP_MODEL].topSpeed * CLIP_MULT
local ok, clipResult = pcall(run, CLIP_MODEL, clipSpeed, true)
local clip = ok and clipResult and clipResult.clip or nil
if not clip or #clip.frames < 2 then
	out("PROBLEM clip: not recorded (%s)", tostring(ok and "no frames" or clipResult))
	return {}
end
out("clip: %d frames recorded, end state health %.1f shield %.1f", #clip.frames, clipResult.health, clipResult.shield)
for _, copy in ipairs(clip.copies) do
	copy.Parent = folder
end
local posed = clip.posed

-- What matters, drawn: the target's health and shield over its head, and a sign saying what hit it.
local victimCopy = clip.copies[3]
local board = Instance.new("BillboardGui")
board.Size = UDim2.fromOffset(320, 110)
board.StudsOffset = Vector3.new(0, 5, 0)
board.AlwaysOnTop = true
board.Adornee = victimCopy:FindFirstChild("Head")
board.Parent = folder
local function bar(y, colour)
	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 0, 30)
	back.Position = UDim2.fromOffset(0, y)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	back.BorderSizePixel = 0
	back.Parent = board
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = colour
	fill.BorderSizePixel = 0
	fill.Parent = back
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0
	text.Font = Enum.Font.GothamBold
	text.TextSize = 22
	text.ZIndex = 2
	text.Parent = back
	return fill, text
end
local shieldFill, shieldText = bar(0, Color3.fromRGB(60, 140, 255))
local healthFill, healthText = bar(36, Color3.fromRGB(70, 200, 90))
local verdict = Instance.new("TextLabel")
verdict.Size = UDim2.new(1, 0, 0, 36)
verdict.Position = UDim2.fromOffset(0, 72)
verdict.BackgroundTransparency = 1
verdict.TextColor3 = Color3.new(1, 1, 1)
verdict.TextStrokeTransparency = 0
verdict.Font = Enum.Font.GothamBlack
verdict.TextSize = 30
verdict.Parent = board

-- What hit it, above the lane (a billboard, so it always reads the right way round).
local sign = Instance.new("Part")
sign.Anchored = true
sign.Transparency = 1
sign.CanCollide = false
sign.Size = Vector3.new(1, 1, 1)
sign.Position = clip.bodyAt + Vector3.new(20, 17, -6)
sign.Parent = folder
local signBoard = Instance.new("BillboardGui")
signBoard.Size = UDim2.fromOffset(720, 44)
signBoard.AlwaysOnTop = true
signBoard.Adornee = sign
signBoard.Parent = folder
local label = Instance.new("TextLabel")
label.Size = UDim2.fromScale(1, 1)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
label.BackgroundTransparency = 0.2
label.TextColor3 = Color3.new(1, 1, 1)
label.TextSize = 24
label.Font = Enum.Font.GothamBold
label.Text = string.format("%s at %.0f studs/s (%.1fx top speed) into 100 health + 100 shield", CLIP_MODEL, clipSpeed, CLIP_MULT)
label.Parent = signBoard

-- The lane the run was on (its slab went with the run).
local floor = Instance.new("Part")
floor.Anchored = true
floor.Size = Vector3.new(40, 4, 900)
floor.Position = Vector3.new(clip.bodyAt.X, -2, CZ)
floor.Material = Enum.Material.Asphalt
floor.Color = Color3.fromRGB(70, 70, 75)
floor.Parent = folder

local function pose(frame)
	if frame.pose then
		for i, part in ipairs(posed) do
			if frame.pose[i] then
				part.CFrame = frame.pose[i]
			end
		end
	end
	shieldFill.Size = UDim2.fromScale(math.clamp(frame.shield / 100, 0, 1), 1)
	healthFill.Size = UDim2.fromScale(math.clamp(frame.health / 100, 0, 1), 1)
	shieldText.Text = string.format("SHIELD %.0f", frame.shield)
	healthText.Text = string.format("HEALTH %.0f", math.max(frame.health, 0))
	verdict.Text = frame.health <= 0 and "DEAD" or ""
	verdict.TextColor3 = Color3.fromRGB(255, 70, 70)
end

-- Side on to the lane at the hit, far enough back that the run-in and the throw are both in frame.
local views = {}
local eye = clip.bodyAt + Vector3.new(-48, 12, -6)
local look = clip.bodyAt + Vector3.new(0, 2, -6)
local count = #clip.frames
for index = 1, count + 5 do
	local frame = clip.frames[math.min(index, count)]
	table.insert(views, {
		name = string.format("clip_%03d", index),
		settle = 0.05,
		hold = 0.3,
		setup = function(_, camera)
			pose(frame)
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(eye, look)
		end,
	})
end
return views
