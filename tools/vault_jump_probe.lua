-- Vault-jump probe (Destruction tab; Oliver's #115 "make it easier to vault through windows").
--
-- Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vault_jump_probe.lua -OutDir <folder> -TimeoutSeconds 900
--
-- The census in tools/window_vault_probe.lua showed the one dimension a player cannot control: a jump
-- pressed more than ~50 ms before a window killed the vault, because Parkour.Find measured the sill from
-- the RISING feet (rise 1.5 at feet+2.5, "a step"; nothing found at feet+3.5, "too high"). Find now
-- measures a vault from the ground the body left while it is within Parkour.JumpGrace of it, and the
-- client only lets a vault take over a jump that would not clear the obstacle on its own.
--
--   C  the same census, feet 0..7 above the ground at a real window: want the ceiling (17 of 19, two
--      windows have interior behind them) THROUGH a jump's apex (6.4), not 17 then 0 at 2.5.
--   R  the rails table: thin rails 1.6..6.0 high, the body 0..6 studs into a jump; per rail, what Find
--      plans and whether MovementClient's take-over rule (repeated here with its own equations, as
--      movement_probe repeats the slide's) would leave the jump alone. A rail the jump clears must stay
--      a hop; a window must take over.
--   P  planted fault, invariant "a vault is never planned onto a top higher than VaultMaxRise above the
--      ground the body left": a 6-high thin wall, feet+2.5, must never plan a vault. Then the same call
--      told the ground is at the feet (the old frame) must be CAUGHT by the detector, or the plant did
--      not fire.
--   G  the server's glass box from a body in the air: ClientParkour with the body at feet+2.5 in front
--      of a real window must still take the pane (the band is measured from the ground under the body).
--   F  grounded regression guard: a bot's TryParkour at a 3.5 fence from the ground still vaults.
-- Then a render of a body mid-jump at a window with the plan Find makes for it drawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local MapData = require(Shared:WaitForChild("MapData"))

local CFG = MovementConfig.Parkour
local ORIGIN = Vector3.new(4000, 1700, -3600)
local SPRINT = 18 * 1.45
local PRESET = MapData.Maps.SahurSprings
local WALL_THICKNESS = 1.4

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

local function block(parent, size, cframe, color, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color or Color3.fromRGB(120, 120, 130)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

local template = nil
local function makeTemplate()
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

local function drive(timeout, step)
	local started = os.clock()
	local finished = false
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if finished then
			return
		end
		local elapsed = os.clock() - started
		local ok, result = pcall(step, dt, elapsed)
		if not ok then
			note("step error: %s", tostring(result))
			finished = true
		elseif result or elapsed > timeout then
			finished = true
		end
	end)
	while not finished do
		task.wait()
	end
	connection:Disconnect()
end

local function ensureRunning()
	if not RunService:IsRunning() then
		RunService:Run()
		task.wait(4)
	end
end

local lastHolder = nil
local function freshHolder()
	if lastHolder then
		lastHolder:Destroy()
		lastHolder = nil
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = workspace
	end
	local holder = Instance.new("Folder")
	holder.Name = "VaultJumpProbe"
	holder.Parent = map
	lastHolder = holder
	return holder
end

local function requireModules()
	local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
	return {
		MapBuildings = require(modules:WaitForChild("MapBuildings")),
		MovementService = require(modules:WaitForChild("MovementService")),
		CombatService = require(modules:WaitForChild("CombatService")),
		Combatants = require(modules:WaitForChild("Combatants")),
		MatchService = require(modules:WaitForChild("MatchService")),
	}
end

local function buildRow(M, holder, names, seed)
	local ground = block(holder, Vector3.new(560, 1, 300), CFrame.new(ORIGIN + Vector3.new(0, -0.5, 0)), Color3.fromRGB(96, 130, 78))
	ground.Name = "ProbeGround"
	ground.Material = Enum.Material.Grass
	local built = {}
	local x = -(#names - 1) * 80
	for _, name in ipairs(names) do
		math.randomseed(seed)
		local plan = table.clone(PLANS[name])
		local origin = ORIGIN + Vector3.new(x, 0, 0)
		local before = {}
		for _, child in ipairs(holder:GetChildren()) do
			before[child] = true
		end
		local ok, err = pcall(M.MapBuildings.BuildBuilding, holder, origin, PRESET, {}, { weapon = {}, heal = {}, item = {} }, plan, 0)
		if not ok then
			note("BuildBuilding %s FAILED: %s", name, tostring(err))
		end
		for _, child in ipairs(holder:GetChildren()) do
			if not before[child] and child:IsA("Model") then
				table.insert(built, { name = name, model = child, origin = origin, plan = plan })
			end
		end
		x += 160
	end
	return built
end

local function groundPanes(entry)
	local panes = {}
	for _, part in ipairs(entry.model:GetChildren()) do
		if part:IsA("BasePart") and part.Name == "WindowGlass" and part.Position.Y < entry.origin.Y + 12 then
			table.insert(panes, part)
		end
	end
	table.sort(panes, function(a, b)
		local na, nb = a.CFrame.LookVector, b.CFrame.LookVector
		local ka, kb = math.round(na.X) * 3 + math.round(na.Z), math.round(nb.X) * 3 + math.round(nb.Z)
		if ka ~= kb then
			return ka < kb
		end
		return a.Position.X + a.Position.Z < b.Position.X + b.Position.Z
	end)
	return panes
end

local function firstBackPane(entry)
	for _, pane in ipairs(groundPanes(entry)) do
		if pane.CFrame.LookVector.Z > 0.5 then
			return pane
		end
	end
	return groundPanes(entry)[1]
end

-- Places `rig` with its feet `lift` above `groundY`, facing `dir`, and gives physics one frame.
local function place(rig, stand, pos, dir)
	rig:PivotTo(CFrame.lookAt(pos, pos + dir))
	rig.HumanoidRootPart.AssemblyLinearVelocity = Vector3.zero
	task.wait()
end

-- MovementClient's take-over rule, with its own equations: would the jump clear the plan's obstacle?
-- `vy` is the upward speed a plain jump still has `lift` studs up; `toward` the horizontal speed.
local function jumpClears(plan, feetY, vy, toward, rootPosition, rootDepth)
	if plan.panes and #plan.panes > 0 then
		return false, "pane in the box"
	end
	if toward <= 1 then
		return false, "not moving"
	end
	local near = math.max((flat(plan.points[2]) - flat(rootPosition)):Dot(plan.forward), 0)
	local far = near + plan.depth + rootDepth + 0.6
	for _, distance in ipairs({ near, far }) do
		local t = distance / toward
		if feetY + vy * t - 0.5 * workspace.Gravity * t * t < plan.topY + 0.3 then
			return false, string.format("feet %.1f below top+0.3 at %.1f studs", plan.topY + 0.3 - (feetY + vy * t - 0.5 * workspace.Gravity * t * t), distance)
		end
	end
	return true, "clears"
end

local measurement = {
	name = "vault_jump_probe",
	settle = 1,
	hold = 1,
	setup = function(folder, camera)
		ensureRunning()
		local M = requireModules()
		template = template or makeTemplate()
		if not template then
			note("no rig, giving up")
			return
		end
		local g = workspace.Gravity
		local v0 = StarterPlayer.CharacterUseJumpPower and StarterPlayer.CharacterJumpPower or math.sqrt(2 * g * StarterPlayer.CharacterJumpHeight)
		local apex = v0 * v0 / (2 * g)
		note("jump v %.1f gravity %.1f apex %.2f; Parkour.JumpGrace %s; VaultMaxRise %.1f MinRise %.1f", v0, g, apex, tostring(CFG.JumpGrace), CFG.VaultMaxRise, CFG.MinRise)
		if CFG.JumpGrace == nil then
			note("JumpGrace is NOT in MovementConfig: this place does not carry the #115 change (baseline run)")
		end

		local rig = template:Clone()
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local root = rig.HumanoidRootPart
		humanoid.AutoRotate = false
		humanoid.WalkSpeed = SPRINT
		local stand = humanoid.HipHeight + root.Size.Y / 2
		rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, stand, 140)))
		rig.Parent = folder
		task.wait(1)

		-- C: the window census over the feet.
		local holder = freshHolder()
		local built = buildRow(M, holder, { "house", "tower", "warehouse" }, 7)
		task.wait(0.5)
		local panes = {}
		for _, entry in ipairs(built) do
			for _, pane in ipairs(groundPanes(entry)) do
				table.insert(panes, pane)
			end
		end
		note("C census: %d ground-floor panes across %d buildings, body 1.6 from the face, sprint, facing square", #panes, #built)
		for _, lift in ipairs({ 0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0, 6.5, 7.0 }) do
			local counts, n = {}, 0
			for _, pane in ipairs(panes) do
				local normal = pane.CFrame.LookVector
				local face = pane.Position + normal * (WALL_THICKNESS / 2)
				local pos = Vector3.new(face.X, ORIGIN.Y + stand + lift + 0.02, face.Z) + normal * 1.6
				place(rig, stand, pos, -normal)
				local plan, reason = Parkour.Find(rig, -normal, { groundY = ORIGIN.Y, speed = SPRINT, grounded = lift == 0 })
				local outcome = plan and plan.kind or reason
				counts[outcome] = (counts[outcome] or 0) + 1
				n += 1
			end
			local list = {}
			for outcome, count in pairs(counts) do
				table.insert(list, { outcome = outcome, count = count })
			end
			table.sort(list, function(a, b)
				return a.count > b.count
			end)
			local shown = {}
			for index = 1, math.min(3, #list) do
				table.insert(shown, string.format("%s %d", list[index].outcome, list[index].count))
			end
			note("C feetUp %-4s: vault %2d/%d | %s", tostring(lift), counts.vault or 0, n, table.concat(shown, ", "))
		end

		-- R: rails. Thin, 12 long, on the plate well clear of the buildings.
		local rails = {}
		for index, height in ipairs({ 1.6, 2.0, 2.4, 3.0, 4.0, 4.8, 6.0 }) do
			local z = ORIGIN.Z + 100 + index * 14
			local rail = block(holder, Vector3.new(12, height, 0.4), CFrame.new(ORIGIN.X + 200, ORIGIN.Y + height / 2, z), Color3.fromRGB(150, 110, 70))
			rail.Name = "ProbeRail"
			table.insert(rails, { height = height, part = rail, z = z })
		end
		note("R rails: per rail height, the body 1.6 before it at sprint; feet 0..6 into a jump; Find's kind, then the client's take-over rule (hop = the jump is left alone)")
		for _, rail in ipairs(rails) do
			local cells = {}
			for _, lift in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
				local pos = Vector3.new(ORIGIN.X + 200, ORIGIN.Y + stand + lift + 0.02, rail.z - 0.2 - 1.6)
				place(rig, stand, pos, Vector3.new(0, 0, 1))
				local plan, reason = Parkour.Find(rig, Vector3.new(0, 0, 1), { groundY = ORIGIN.Y, speed = SPRINT, grounded = lift == 0 })
				local cell
				if plan and plan.kind == "vault" then
					if lift == 0 then
						cell = "VAULT"
					else
						local vy = math.sqrt(math.max(0, v0 * v0 - 2 * g * lift))
						local clears = jumpClears(plan, ORIGIN.Y + lift, vy, SPRINT, root.Position, root.Size.Z)
						cell = clears and "hop" or "VAULT"
					end
				elseif plan then
					cell = plan.kind
				else
					cell = reason
				end
				table.insert(cells, string.format("%d:%s", lift, cell))
			end
			note("R rail %.1f: %s", rail.height, table.concat(cells, " | "))
		end

		-- P: the invariant, and the plant that proves the detector can fail.
		local wall = nil
		for _, rail in ipairs(rails) do
			if rail.height == 6.0 then
				wall = rail
			end
		end
		if wall then
			local pos = Vector3.new(ORIGIN.X + 200, ORIGIN.Y + stand + 2.5 + 0.02, wall.z - 0.2 - 1.6)
			place(rig, stand, pos, Vector3.new(0, 0, 1))
			local honest = Parkour.Find(rig, Vector3.new(0, 0, 1), { groundY = ORIGIN.Y, speed = SPRINT, grounded = false })
			local honestKind = honest and honest.kind or "nil"
			local violation = honest and honest.kind == "vault" and honest.topY - ORIGIN.Y > CFG.VaultMaxRise
			note("P invariant (6.0 wall, feet+2.5, ground told truthfully): Find -> %s; top %.1f above the ground left -> %s", honestKind,
				honest and honest.topY - ORIGIN.Y or -1, violation and "VIOLATION" or "holds")
			-- The plant: the ground claimed to be at the feet (the old frame). A vault onto a 6.0 top must then be
			-- planned, and the detector, which measures from the TRUE ground, must flag it.
			local lied = Parkour.Find(rig, Vector3.new(0, 0, 1), { groundY = ORIGIN.Y + 2.5, speed = SPRINT, grounded = false })
			local caught = lied and lied.kind == "vault" and lied.topY - ORIGIN.Y > CFG.VaultMaxRise
			note("P plant (ground claimed at the feet): Find -> %s; detector %s -> plant %s", lied and lied.kind or "nil",
				caught and "CAUGHT the 6.0 vault" or "did not see a vault to catch", caught and "FIRED" or "DID NOT FIRE")
		end

		-- G: the glass box from the air.
		local stubs = { SpendStamina = M.MovementService.SpendStamina, GetStamina = M.MovementService.GetStamina, SetCrouching = M.MovementService.SetCrouching }
		M.MovementService.SpendStamina = function()
			return true
		end
		M.MovementService.GetStamina = function()
			return 1, false
		end
		M.MovementService.SetCrouching = function()
			return false
		end
		local bootstrapInstance = M.MovementService.SpendStamina == M.MatchService.SpendStamina
		if not bootstrapInstance then
			M.MovementService.BreakPane = function(token, pane, from)
				return M.CombatService.DamageDestructible ~= nil and M.CombatService.DamageDestructible(token, pane, 1, from) > 0
			end
		end
		local fakePlayer = { isBot = true, name = "ProbePlayer", character = rig, Character = rig, Name = "ProbePlayer" }
		local house = built[1]
		local gPane = house and firstBackPane(house)
		if gPane then
			local normal = gPane.CFrame.LookVector
			local face = gPane.Position + normal * (WALL_THICKNESS / 2)
			local pos = Vector3.new(face.X, ORIGIN.Y + stand + 2.5, face.Z) + normal * 1.6
			rig:PivotTo(CFrame.lookAt(pos, pos - normal))
			root.Anchored = true
			task.wait(0.2)
			M.MovementService.LastGlass = nil
			M.MovementService.ClientParkour(fakePlayer, "vault", 4.0, 0.5)
			task.wait(0.3)
			local record = M.MovementService.LastGlass
			note("G glass from the air (body at feet+2.5, 1.6 before a house window): pane %s; LastGlass %s -> %s", gPane.Parent and "SURVIVED" or "gone",
				record and string.format("found %d broke %d", record.found, record.broken) or "nil", (not gPane.Parent) and "PASS" or "FAIL")
			root.Anchored = false
		end

		-- F: a grounded bot at a 3.5 fence, as before.
		local fence = block(holder, Vector3.new(0.4, 3.5, 14), CFrame.new(ORIGIN.X - 200, ORIGIN.Y + 1.75, ORIGIN.Z + 120), Color3.fromRGB(170, 120, 60))
		fence.Name = "ProbeFence"
		M.Combatants.Register(rig, { isBot = true, name = "ProbeVaulter", character = rig })
		local start = Vector3.new(ORIGIN.X - 200 - 8, ORIGIN.Y + stand, ORIGIN.Z + 120)
		rig:PivotTo(CFrame.lookAt(start, start + Vector3.new(1, 0, 0)))
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.5)
		local kind, why, startedAt = nil, nil, nil
		drive(6, function(_, elapsed)
			if not kind then
				humanoid:Move(Vector3.new(1, 0, 0), false)
				if (ORIGIN.X - 200 - 0.2) - root.Position.X <= 1.6 and elapsed > 0.2 then
					kind, why = M.MovementService.TryParkour(rig, Vector3.new(1, 0, 0), { speed = math.max(0, root.AssemblyLinearVelocity.X), groundY = ORIGIN.Y })
					startedAt = elapsed
					if not kind then
						return true
					end
				end
				return elapsed > 4
			end
			return elapsed - startedAt > 1.2
		end)
		humanoid:Move(Vector3.zero, false)
		note("F grounded bot at a 3.5 fence: %s%s; ended %+.1f past it -> %s", tostring(kind), kind and "" or (" (" .. tostring(why) .. ")"),
			root.Position.X - (ORIGIN.X - 200), kind == "vault" and "PASS" or "FAIL")
		M.Combatants.Unregister(rig)
		M.MovementService.SpendStamina = stubs.SpendStamina
		M.MovementService.GetStamina = stubs.GetStamina
		M.MovementService.SetCrouching = stubs.SetCrouching

		if lastHolder then
			lastHolder:Destroy()
			lastHolder = nil
		end
		camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 40, 200), ORIGIN)
	end,
}

local function occlusion(camera, target, label, allow)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local from = camera.CFrame.Position
	local result = workspace:Raycast(from, target - from, params)
	if not result then
		note("view %s: camera -> target clear (%.1f studs)", label, (target - from).Magnitude)
		return
	end
	local blocker = result.Instance
	if allow and (blocker == allow or blocker:IsDescendantOf(allow)) then
		note("view %s: camera -> target reaches %s first (the subject itself)", label, blocker:GetFullName())
	else
		note("view %s: camera -> target OCCLUDED by %s at %.1f studs", label, blocker:GetFullName(), result.Distance)
	end
end

local midJumpView = {
	name = "window_mid_jump_plan",
	settle = 1.5,
	setup = function(folder, camera)
		ensureRunning()
		local M = requireModules()
		template = template or makeTemplate()
		if not template then
			return
		end
		local holder = freshHolder()
		local built = buildRow(M, holder, { "house" }, 7)
		local entry = built[1]
		local pane = entry and firstBackPane(entry)
		if not pane then
			note("view mid-jump: no pane")
			return
		end
		local normal = pane.CFrame.LookVector
		local tangent = normal:Cross(Vector3.yAxis).Unit
		local face = pane.Position + normal * (WALL_THICKNESS / 2)
		local rig = template:Clone()
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local root = rig.HumanoidRootPart
		local stand = humanoid.HipHeight + root.Size.Y / 2
		local lift = 2.5
		local spot = Vector3.new(face.X, ORIGIN.Y + stand + lift, face.Z) + normal * 1.6
		rig:PivotTo(CFrame.lookAt(spot, spot - normal))
		root.Anchored = true
		rig.Parent = folder
		task.wait()
		local plan, reason = Parkour.Find(rig, -normal, { groundY = ORIGIN.Y, speed = SPRINT, grounded = false })
		if plan then
			for index, point in ipairs(plan.points) do
				local ball = block(folder, Vector3.new(0.5, 0.5, 0.5), CFrame.new(point), Color3.fromRGB(60, 255, 90), { Material = Enum.Material.Neon, CanCollide = false, CanQuery = false })
				ball.Shape = Enum.PartType.Ball
				if index > 1 then
					local previous = plan.points[index - 1]
					block(folder, Vector3.new(0.12, 0.12, (point - previous).Magnitude), CFrame.lookAt((point + previous) / 2, point), Color3.fromRGB(60, 255, 90),
						{ Material = Enum.Material.Neon, CanCollide = false, CanQuery = false })
				end
			end
		end
		note("view mid-jump: body feet %.1f above the ground, 1.6 before a house window: Find -> %s%s", lift, plan and plan.kind or "nil",
			plan and string.format(" (rise %.1f, %d points, %d pane(s) in the box)", plan.rise, #plan.points, plan.panes and #plan.panes or 0) or (" (" .. tostring(reason) .. ")"))
		local target = Vector3.new(face.X, ORIGIN.Y + 5.5, face.Z)
		camera.FieldOfView = 55
		camera.CFrame = CFrame.lookAt(target + normal * 10 + tangent * 8 + Vector3.new(0, 3, 0), target)
		occlusion(camera, root.Position, "mid-jump/body", rig)
		occlusion(camera, pane.Position, "mid-jump/pane", pane)
	end,
}

return { measurement, midJumpView }
