-- Window vault-OUT probe (Oliver, 2026-09-24: "i cant vault back out through a window from the inside").
--
-- Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/window_vault_out_probe.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- window_vault_probe's census only ever POSES a body and asks Parkour.Find. The bug is past that, in
-- MovementClient.tryParkour's air rule: a vault started in the air stands aside when the jump alone
-- would clear the obstacle, and only an INTACT pane overrode that. Going back out, the pane is always
-- broken (you came in through it), and the inside sill is 0.5 lower than the outside one.
--
-- So this runs the whole thing with physics on REAL MapBuildings buildings: a rig runs at a ground-floor
-- window and jumps, and every Heartbeat a copy of tryParkour (mantle apex rule, air-vault rule, stepMove)
-- decides, exactly as the client does. Each run ends OUT (through the window), SILL (standing in the
-- frame) or IN (still on the side it started). Rules:
--   old  the air rule as it was: glass overrides, nothing else does
--   new  the fix: anything overhead closer than a body's height above the top also overrides
-- Sides: inside with the pane broken (the bug), outside with the pane broken (the control: Oliver says
-- that works, so if old/outside fails too the simulation is wrong, not the game), and inside with the
-- pane intact under the old rule (the census's case).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local MapData = require(Shared:WaitForChild("MapData"))

local CFG = MovementConfig.Parkour
local ORIGIN = Vector3.new(4000, 1500, -3000)
local WALK, SPRINT = 18, 18 * 1.45
local PRESET = MapData.Maps.SahurSprings
local WALL_THICKNESS = 1.4
local RUNUP = 9
local HOLD_JUMP = 0.25
local RUN_TIME = 2.6

local PLANS = {
	house = { archetype = "house", width = 32, depth = 30, floors = 2, dock = false },
	tower = { archetype = "tower", width = 30, depth = 30, floors = 3, dock = false },
	warehouse = { archetype = "warehouse", width = 44, depth = 38, floors = 1, dock = true },
}

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function ensureRunning()
	if not RunService:IsRunning() then
		RunService:Run()
		task.wait(4)
	end
end

local function makeRig()
	for attempt = 1, 3 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			return model
		end
		note("rig attempt %d failed: %s", attempt, tostring(model))
		task.wait(2)
	end
	return nil
end

local function buildRow(holder)
	local ground = Instance.new("Part")
	ground.Name = "ProbeGround"
	ground.Anchored = true
	ground.Size = Vector3.new(560, 1, 300)
	ground.CFrame = CFrame.new(ORIGIN + Vector3.new(0, -0.5, 0))
	ground.Parent = holder
	local MapBuildings = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("MapBuildings"))
	local built = {}
	local x = -160
	for _, name in ipairs({ "house", "tower", "warehouse" }) do
		math.randomseed(7)
		local before = {}
		for _, child in ipairs(holder:GetChildren()) do
			before[child] = true
		end
		local origin = ORIGIN + Vector3.new(x, 0, 0)
		local ok, err = pcall(MapBuildings.BuildBuilding, holder, origin, PRESET, {}, { weapon = {}, heal = {}, item = {} }, table.clone(PLANS[name]), 0)
		if not ok then
			note("BuildBuilding %s FAILED: %s", name, tostring(err))
		end
		for _, child in ipairs(holder:GetChildren()) do
			if not before[child] and child:IsA("Model") then
				table.insert(built, { name = name, model = child, origin = origin })
			end
		end
		x += 160
	end
	return built
end

-- Ground-floor panes, at most `per` per building, spread across its walls.
local function pickPanes(built, per)
	local picked = {}
	for _, entry in ipairs(built) do
		local panes = {}
		for _, part in ipairs(entry.model:GetChildren()) do
			if part:IsA("BasePart") and part.Name == "WindowGlass" and part.Position.Y < entry.origin.Y + 12 then
				table.insert(panes, part)
			end
		end
		table.sort(panes, function(a, b)
			return a.Position.X + a.Position.Z * 0.37 < b.Position.X + b.Position.Z * 0.37
		end)
		local stride = math.max(1, math.floor(#panes / per))
		local count = 0
		for index = 1, #panes, stride do
			if count >= per then
				break
			end
			table.insert(picked, { building = entry.name, cframe = panes[index].CFrame, size = panes[index].Size, pane = panes[index] })
			count += 1
		end
	end
	return picked
end

--------------------------------------------------------------------------------
-- MovementClient.tryParkour, copied (only the parts that decide), with the air rule switchable.
--------------------------------------------------------------------------------

local function openAbove(rig, plan)
	local mid = (plan.points[2] + plan.points[3]) / 2
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig }
	params.RespectCanCollide = true
	local body = Parkour.Metrics(rig)
	local need = (body and body.height or 5) + 0.3
	return workspace:Raycast(Vector3.new(mid.X, plan.topY + 0.2, mid.Z), Vector3.new(0, need, 0), params) == nil
end

local function decide(rig, humanoid, root, direction, state, rule)
	local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
	local velocity = flat(root.AssemblyLinearVelocity)
	local speed = math.max(velocity:Dot(direction), 0)
	local recentlyGrounded = grounded or os.clock() - state.groundedAt < 0.35
	local plan = Parkour.Find(rig, direction, { groundY = state.lastGroundY, speed = speed, grounded = grounded, allowVault = recentlyGrounded })
	if not plan then
		return nil
	end
	if plan.kind == "mantle" and speed >= 8 then
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
		local jumpHeight = humanoid.UseJumpPower and humanoid.JumpPower ^ 2 / (2 * workspace.Gravity) or humanoid.JumpHeight
		local rising = math.max(root.AssemblyLinearVelocity.Y, 0)
		local apex = grounded and feet + jumpHeight or feet + rising * rising / (2 * workspace.Gravity)
		if plan.topY < apex - 0.6 then
			return nil
		end
	end
	local override = (plan.panes and #plan.panes > 0) or (rule == "new" and not openAbove(rig, plan))
	if plan.kind == "vault" and not grounded and not override then
		local feet = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
		local v = root.AssemblyLinearVelocity
		local toward = flat(v):Dot(plan.forward)
		if toward > 1 then
			local near = math.max((flat(plan.points[2]) - flat(root.Position)):Dot(plan.forward), 0)
			local far = near + plan.depth + root.Size.Z + 0.6
			local clears = true
			for _, distance in ipairs({ near, far }) do
				local t = distance / toward
				if feet + v.Y * t - 0.5 * workspace.Gravity * t * t < plan.topY + 0.3 then
					clears = false
				end
			end
			if clears then
				state.stoodAside += 1
				return nil
			end
		end
	end
	return plan
end

-- One run. `side` is "inside" or "outside"; `jumpAt` how far from the face the jump is pressed (nil:
-- walk into the wall and press it standing still). Returns OUT / SILL / IN / NOAPPROACH and the move.
local function run(rig, humanoid, root, window, side, speed, jumpAt, rule)
	local normal = window.cframe.LookVector
	local outward = side == "inside" and -normal or normal
	local centre = window.cframe.Position
	local faceSide = centre + outward * (WALL_THICKNESS / 2)
	local floorY = side == "inside" and ORIGIN.Y + 0.5 or ORIGIN.Y
	local stand = humanoid.HipHeight + root.Size.Y / 2
	local start = Vector3.new(faceSide.X, floorY + stand + 0.05, faceSide.Z) + outward * RUNUP
	local direction = flat(-outward).Unit

	humanoid.WalkSpeed = speed > 0 and speed or WALK
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	rig:PivotTo(CFrame.lookAt(start, start + direction))
	humanoid:ChangeState(Enum.HumanoidStateType.Running)
	task.wait(0.35)

	local state = { lastGroundY = nil, groundedAt = 0, stoodAside = 0 }
	local pressedAt, active, moveKind, reached = nil, nil, nil, false
	local started = os.clock()
	local done = false
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if done then
			return
		end
		local now = os.clock()
		local distance = (flat(root.Position) - flat(faceSide)):Dot(outward)
		if humanoid.FloorMaterial ~= Enum.Material.Air and not active then
			state.lastGroundY = root.Position.Y - humanoid.HipHeight - root.Size.Y / 2
			state.groundedAt = now
		end
		if active then
			local position, finished = Parkour.PositionAt(active, now - active.startedAt)
			root.CFrame = CFrame.lookAt(position, position + active.forward)
			root.AssemblyLinearVelocity = Vector3.zero
			if finished then
				root.AssemblyLinearVelocity = active.exitVelocity
				active = nil
			end
		else
			humanoid:Move(direction, false)
			if not pressedAt then
				local press = (jumpAt and distance <= jumpAt) or (not jumpAt and (distance <= 1.6 or now - started > 1.2))
				if press then
					reached = true
					pressedAt = now
					humanoid.Jump = true
				end
			end
			if pressedAt and now - pressedAt <= HOLD_JUMP and not moveKind then
				local plan = decide(rig, humanoid, root, direction, state, rule)
				if plan then
					plan.startedAt = now
					active, moveKind = plan, plan.kind
				end
			end
		end
		if now - started > RUN_TIME then
			done = true
		end
	end)
	while not done do
		task.wait()
	end
	connection:Disconnect()
	humanoid:Move(Vector3.zero, false)

	if not reached then
		return "NOAPPROACH", moveKind, state.stoodAside
	end
	local across = (flat(root.Position) - flat(centre)):Dot(-outward)
	if across > WALL_THICKNESS / 2 + 0.5 then
		return "OUT", moveKind, state.stoodAside
	elseif across > -(WALL_THICKNESS / 2 + 0.5) and root.Position.Y > floorY + 3 then
		return "SILL", moveKind, state.stoodAside
	end
	return "IN", moveKind, state.stoodAside
end

local measurement = {
	name = "window_vault_out_probe",
	settle = 1,
	hold = 1,
	setup = function(folder, camera)
		ensureRunning()
		local map = workspace:FindFirstChild("Map") or Instance.new("Folder")
		map.Name = "Map"
		map.Parent = workspace
		local holder = Instance.new("Folder")
		holder.Name = "WindowOutProbe"
		holder.Parent = map
		local built = buildRow(holder)
		task.wait(0.5)
		local windows = pickPanes(built, 3)
		note("windows: %d ground-floor panes across %d buildings", #windows, #built)

		local rig = makeRig()
		if not rig then
			note("no rig, giving up")
			return
		end
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
		humanoid.JumpPower = StarterPlayer.CharacterJumpPower
		humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
		humanoid.MaxSlopeAngle = StarterPlayer.CharacterMaxSlopeAngle
		local root = rig.HumanoidRootPart
		rig.Parent = folder
		task.wait(1)
		local body = Parkour.Metrics(rig)
		note("rig: stand %.2f, height %.2f; window opening %.1f tall", body.stand, body.height, 8.5 - 3.5)

		-- Self-test: the openAbove instrument must see a lintel over a window and nothing over open ground.
		do
			local w = windows[1]
			local normal = w.cframe.LookVector
			local fake = { points = { Vector3.zero, w.cframe.Position - normal * 0.3, w.cframe.Position + normal * 0.3 },
				topY = w.cframe.Position.Y - w.size.Y / 2 + 0.1 }
			local open = { points = { Vector3.zero, ORIGIN + Vector3.new(0, 0, 120), ORIGIN + Vector3.new(0, 0, 121) }, topY = ORIGIN.Y + 1 }
			local a, b = openAbove(rig, fake), openAbove(rig, open)
			note("self-test openAbove: window %s (want false), open ground %s (want true) -> %s", tostring(a), tostring(b),
				(a == false and b == true) and "OK" or "INSTRUMENT BROKEN")
		end

		local cases = {}
		for _, speed in ipairs({ WALK, SPRINT }) do
			for _, jumpAt in ipairs({ 1.2, 2.2, 3.2, 4.5 }) do
				table.insert(cases, { speed = speed, jumpAt = jumpAt, label = string.format("run %4.1f jump at %.1f", speed, jumpAt) })
			end
		end
		table.insert(cases, { speed = 0, jumpAt = nil, label = "walk into the wall, then jump" })

		local function sweep(title, side, rule, intact)
			note("== %s ==", title)
			local total = { OUT = 0, SILL = 0, IN = 0, NOAPPROACH = 0 }
			for _, case in ipairs(cases) do
				local tally = { OUT = 0, SILL = 0, IN = 0, NOAPPROACH = 0 }
				local kinds, aside = {}, 0
				for _, window in ipairs(windows) do
					-- A fresh pane state per run: broken means removed, intact means put back.
					if window.pane and window.pane.Parent and not intact then
						window.pane.Parent = nil
					elseif intact and window.pane and not window.pane.Parent then
						window.pane.Parent = window.home
					end
					local outcome, kind, stood = run(rig, humanoid, root, window, side, case.speed, case.jumpAt, rule)
					tally[outcome] += 1
					total[outcome] += 1
					kinds[kind or "jump"] = (kinds[kind or "jump"] or 0) + 1
					aside += stood
				end
				local kindText = {}
				for kind, count in pairs(kinds) do
					table.insert(kindText, kind .. " " .. count)
				end
				table.sort(kindText)
				note("  %-30s OUT %d SILL %d IN %d (no approach %d) | %s | vault stood aside %d", case.label, tally.OUT, tally.SILL, tally.IN,
					tally.NOAPPROACH, table.concat(kindText, ", "), aside)
			end
			note("  TOTAL %s: OUT %d SILL %d IN %d (no approach %d)", title, total.OUT, total.SILL, total.IN, total.NOAPPROACH)
		end

		for _, window in ipairs(windows) do
			window.home = window.pane.Parent
		end
		sweep("inside, glass intact, OLD rule (the census case)", "inside", "old", true)
		sweep("outside, glass broken, OLD rule (control: Oliver says this works)", "outside", "old", false)
		sweep("inside, glass broken, OLD rule (the bug)", "inside", "old", false)
		sweep("inside, glass broken, NEW rule (the fix)", "inside", "new", false)
		sweep("outside, glass broken, NEW rule (no regression)", "outside", "new", false)
		note("done")

		camera.CFrame = CFrame.lookAt(windows[1].cframe.Position + windows[1].cframe.LookVector * 20 + Vector3.new(0, 6, 0), windows[1].cframe.Position)
	end,
}

return { measurement }
